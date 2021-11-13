package main;

use strict;
use warnings;
use POSIX;
use Time::HiRes qw(usleep nanosleep);


my %SPI_CFG = (
  'SPI_CPHA' =>		0x01,
  'SPI_CPOL' =>		0x02,
  'SPI_MODE_0' =>	(0|0),
  'SPI_MODE_1' =>	(0|0x01),
  'SPI_MODE_2' =>	(0x02|0),
  'SPI_MODE_3' =>	(0x01|0x02),
  'SPI_CS_HIGH' =>	0x04,
  'SPI_LSB_FIRST' =>0x08,
  'SPI_3WIRE' =>	0x10,
  'SPI_LOOP' =>		0x20,
  'SPI_NO_CS' =>	0x40,
  'SPI_READY' =>	0x80,
  'SPI_TX_DUAL' =>	0x100,
  'SPI_TX_QUAD' =>	0x200,
  'SPI_RX_DUAL' =>	0x400,
  'SPI_RX_QUAD' =>  0x800,
);

my $SPI_IOC_MAGIC='k';
my $check_ioctl_ph=1;
my $SPI_freq = 65536;

my %SPI_MOD = (
'SPI_IOC_MESSAGE1' =>			0x40206b00,
'SPI_IOC_MESSAGE2' =>			0x40406b00,
'SPI_IOC_WR_MODE' => 			0x40016b01,
'SPI_IOC_RD_MODE' => 			0x40016b01,
'SPI_IOC_RD_BITS_PER_WORD' => 	0x80016b03,
'SPI_IOC_WR_BITS_PER_WORD' => 	0x40016b03,
'SPI_IOC_RD_MAX_SPEED_HZ' => 	0x80046b04,
'SPI_IOC_WR_MAX_SPEED_HZ' => 	0x40046b04,
'SPI_IOC_RD_MODE32' => 			0x80046b05,
'SPI_IOC_WR_MODE32' => 			0x40046b05,
);

my %MAX_FLAGS = (
'MAX31865_CONFIG_REG' => 0x00,
'MAX31865_CONFIG_BIAS' => 0x80,
'MAX31865_CONFIG_MODEAUTO' => 0x40,
'MAX31865_CONFIG_MODEOFF' => 0x00,
'MAX31865_CONFIG_1SHOT' => 0x20,
'MAX31865_CONFIG_3WIRE' => 0x10,
'MAX31865_CONFIG_24WIRE' => 0x00,
'MAX31865_CONFIG_FAULTSTAT' => 0x02,
'MAX31865_CONFIG_FILT50HZ' => 0x01,
'MAX31865_CONFIG_FILT60HZ' => 0x00,
'MAX31865_RTDMSB_REG' => 0x01,
'MAX31865_RTDLSB_REG' => 0x02,
'MAX31865_HFAULTMSB_REG' => 0x03,
'MAX31865_HFAULTLSB_REG' => 0x04,
'MAX31865_LFAULTMSB_REG' => 0x05,
'MAX31865_LFAULTLSB_REG' => 0x06,
'MAX31865_FAULTSTAT_REG' => 0x07,
'MAX31865_FAULT_HIGHTHRESH' => 0x80,
'MAX31865_FAULT_LOWTHRESH' => 0x40,
'MAX31865_FAULT_REFINLOW' => 0x20,
'MAX31865_FAULT_REFINHIGH' => 0x10,
'MAX31865_FAULT_RTDINLOW' => 0x08,
'MAX31865_FAULT_OVUV' => 0x04,
);

#struct spi_ioc_transfer {
#	__u64		tx_buf;			Q
#	__u64		rx_buf;			Q
#	__u32		len;			L
#	__u32		speed_hz;		L
#	__u16		delay_usecs;	S
#	__u8		bits_per_word;	C
#	__u8		cs_change;		C
#	__u8		tx_nbits;		C
#	__u8		rx_nbits;		C
#	__u16		pad;			L


my $RTD_A=3.9083e-3;
my $RTD_B=-5.775e-7;
my $rtd_nominal = 1000.0; #For boards with 1kOhm resistor to measure PT1000 - for 100Ohm boards for PT100 change to 100
my $ref_resistor = 4300.0; #For PT100 change to 430
my $corr=1.0; #//Correct error to calibrate resistor/temperature reading
my $len=4;

sub SPI_GetIOCMD ($) {
	my $arg = (1 << 30);
	$arg |= (($_[0]*32) << 16);
	$arg |= (107 << 8);
	return $arg;
}

	eval {require "sys/ioctl.ph"};
	$check_ioctl_ph = 0 if($@);

	my $spidev0="/dev/spidev0.0";
	my $spidev1="/dev/spidev0.1";

	my $handler = undef;
	my $ret = sysopen($handler, $spidev0, O_RDWR);

	if ($ret != 1) { print "Error opening device\n";exit;};

	my $delay=0;
	my $bitsperword=8;

	my $buffer="";

	my $mode=$SPI_CFG{SPI_MODE_1};	
	$mode = pack("C", $mode);
	$ret=ioctl($handler, $SPI_MOD{SPI_IOC_WR_MODE} , $mode) || -1;
	if ($ret==-1) {print "ioctl error\n";exit;};

	my $bits = pack("L", $bitsperword);
	$ret=ioctl($handler, $SPI_MOD{SPI_IOC_WR_BITS_PER_WORD}, $bits) || -1;
	if (!$ret==-1) {print "ioctl error\n";exit;};
		
	my $speed = pack("L", $SPI_freq);
	$ret=ioctl($handler, $SPI_MOD{SPI_IOC_WR_MAX_SPEED_HZ}, $speed) || -1;
	if (!$ret==-1) {print "ioctl error\n";exit;};
		
	my $data1="\0"x8;
	my $data2="\0"x8;
	my $data3="\0"x8;
	my $rep="\0"x8;
	my $ptr1 = unpack( 'L', pack( 'P', $data1 ) );
	my $ptr2 = unpack( 'L', pack( 'P', $data2 ) );
	my $ptr3 = unpack( 'L', pack( 'P', $data3 ) );
	my $ptr = unpack( 'L', pack( 'P', $rep ) );
	$data1 = chr($MAX_FLAGS{MAX31865_CONFIG_REG} & 0x7f)."\0"x8; 
	my $struct1 = pack("QQLLSCCL", $ptr1, 0, 1,$SPI_freq, 0, 8, 0, 0);			

	$data2 = chr(($MAX_FLAGS{MAX31865_CONFIG_REG} | 0x80) & 0xff); #0x80 is write mode
	$data2 .= chr(($MAX_FLAGS{MAX31865_CONFIG_FAULTSTAT}|$MAX_FLAGS{MAX31865_CONFIG_24WIRE}|$MAX_FLAGS{MAX31865_CONFIG_1SHOT}|$MAX_FLAGS{MAX31865_CONFIG_BIAS} & 0xff));
	$data2 .= "\0"x8;
	my $struct2 = pack("QQLLSCCL", $ptr2, 0, 1,$SPI_freq, 65, 8, 0, 0);	#with 65ms delay for conversion		

	$data3 = chr($MAX_FLAGS{MAX31865_RTDMSB_REG})."\0"x8; 
	my $struct3 = pack("QQLLSCCL", $ptr3, $ptr, 2,$SPI_freq, 0, 8, 0, 0);			
	#Send all 3 messages (with builtin delay) at once
	#my $message = $struct1.$struct2.$struct3;
	#$ret=ioctl($handler, SPI_GetIOCMD(3), $message);
	my $message = $struct1.$struct2.$struct3;
	$ret=ioctl($handler, SPI_GetIOCMD(3), $message);
	if (!$ret == -1) {print "ioctl error\n";exit;};
	my @reply=unpack("CC",$rep);
	my $retdata=0;
	for(my $i=0; $i < 2; $i++) {
		$retdata=($retdata<<8)+$reply[$i];
		printf("%02x ",$reply[$i]);
	}
	print "\n";
	printf("ret=%x\n",$retdata);

	$retdata >>=1; 
	my $resistance = ($retdata/32768.0)*$ref_resistor*$corr;
	
	my $Z1 = -$RTD_A;
	my $Z2 = $RTD_A * $RTD_A - (4 * $RTD_B);
	my $Z3 = (4 * $RTD_B) / $rtd_nominal;
	my $Z4 = 2 * $RTD_B;
	my $temp = $Z2 + ($Z3 * $resistance);
	if ($temp>0) {
		$temp = (sqrt($temp) + $Z1) / $Z4;
	} else {$temp=0;}
	
	printf("%3.2f\n",$temp);
		
close($handler);

	
