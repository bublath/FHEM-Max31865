##############################################
# $Id$
# Very basis implementation for the MAX31865 
#
package main;

use strict;
use warnings;
use SetExtensions;
use Scalar::Util qw(looks_like_number);

my %SPI_MAX31865_Config =
(

	'SPI_CFG' => {
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
		'SPI_RX_QUAD' =>  0x800
	},
	'SPI_IOC_MAGIC' => 'k',
	'RTD_A'=> 3.9083e-3,
	'RTD_B'=> -5.775e-7,
	'SPI_MOD' => {
		'SPI_IOC_MESSAGE1' =>			0x40206b00,
		'SPI_IOC_MESSAGE2' =>			0x40406b00,
		'SPI_IOC_WR_MODE' => 			0x40016b01,
		'SPI_IOC_RD_MODE' => 			0x40016b01,
		'SPI_IOC_RD_BITS_PER_WORD' => 	0x80016b03,
		'SPI_IOC_WR_BITS_PER_WORD' => 	0x40016b03,
		'SPI_IOC_RD_MAX_SPEED_HZ' => 	0x80046b04,
		'SPI_IOC_WR_MAX_SPEED_HZ' => 	0x40046b04,
		'SPI_IOC_RD_MODE32' => 			0x80046b05,
		'SPI_IOC_WR_MODE32' => 			0x40046b05
	},
	'MAX_FLAGS' => {
		'CONFIG_REG' => 0x00,
		'CONFIG_BIAS' => 0x80,
		'CONFIG_MODEAUTO' => 0x40,
		'CONFIG_MODEOFF' => 0x00,
		'CONFIG_1SHOT' => 0x20,
		'CONFIG_3WIRE' => 0x10,
		'CONFIG_24WIRE' => 0x00,
		'CONFIG_FAULTSTAT' => 0x02,
		'CONFIG_FILT50HZ' => 0x01,
		'CONFIG_FILT60HZ' => 0x00,
		'RTDMSB_REG' => 0x01,
		'RTDLSB_REG' => 0x02,
		'HFAULTMSB_REG' => 0x03,
		'HFAULTLSB_REG' => 0x04,
		'LFAULTMSB_REG' => 0x05,
		'LFAULTLSB_REG' => 0x06,
		'FAULTSTAT_REG' => 0x07,
		'FAULT_HIGHTHRESH' => 0x80,
		'FAULT_LOWTHRESH' => 0x40,
		'FAULT_REFINLOW' => 0x20,
		'FAULT_REFINHIGH' => 0x10,
		'FAULT_RTDINLOW' => 0x08,
		'FAULT_OVUV' => 0x04
	}
);

my $check_ioctl_ph=1;
my $SPI_freq = 65536;


sub SPI_MAX31865_Initialize($) {
  my ($hash) = @_;

  $hash->{DefFn}     = 	"SPI_MAX31865_Define";
  $hash->{InitFn}  	 =  'SPI_MAX31865_Init';
  $hash->{AttrFn}    = 	"SPI_MAX31865_Attr";
  $hash->{SetFn}     = 	"SPI_MAX31865_Set";
  $hash->{StateFn}   =  "SPI_MAX31865_State";
  $hash->{GetFn}     = 	"SPI_MAX31865_Get";
  $hash->{GetFn}     = 	"SPI_MAX31865_Get";
  $hash->{UndefFn}   = 	"SPI_MAX31865_Undef";
  $hash->{AttrList}  = 	"IODev do_not_notify:1,0 ignore:1,0 showtime:1,0 ".
												"device:0,1 ".
												"PT:100,1000 ".
												"correction: ".
												"spi_frequency ".
												"decimals:0,1,2,3,4,5 ".
												"mode:1SHOT ".
												"poll_interval ".
												"$readingFnAttributes";
}
################################### Todo: Set or Attribute for Mode? Other sets needed?
sub SPI_MAX31865_Set($@) {					#
	my ($hash, @a) = @_;
	my $name =$a[0];
	my $cmd = $a[1];
	my $val = $a[2];	
 
	if ( $cmd && $cmd eq "Update") {
		#Make sure there is no reading cycle running and re-start polling (which starts with an inital read)
		RemoveInternalTimer($hash);
		$hash->{helper}{state}=0; #Reset state machine
		InternalTimer(gettimeofday() + 1, 'SPI_MAX31865_Execute', $hash, 0);
		return undef;
	} else {
		my $list = "Update:noArg";
		return "Unknown argument $a[1], choose one of " . $list if defined $list;
		return "Unknown argument $a[1]";
	}
	if (!defined $hash->{IODev}) {
		readingsSingleUpdate($hash, 'state', 'No IODev defined',0);
		return "$name: no IO device defined";
	}
  	return undef;
}
################################### 
sub SPI_MAX31865_Get($@) {
	#Nothing to be done here, let all updates run asychroniously with timers
	return undef;
}

sub SPI_MAX31865_Execute($@) {
	my ($hash) = @_;
	my $state=$hash->{helper}{state};
	my $channels=$hash->{helper}{channels};
	#Default time between reading channels
	my $nexttimer=0.080; #80ms to give enough time for Bias to fire up and run one 1Shot conversion
	$state=0 unless defined($state);
	if ($state==0) {
		SPI_MAX31865_InitConfig($hash);
		$hash->{helper}{state}=1;
	} elsif ($state==1) {
		$nexttimer = AttrVal($hash->{NAME}, 'poll_interval', 0)*60; 
		SPI_MAX31865_ReadData($hash);
		$hash->{helper}{state}=0;
	} 

	Log3 $hash->{NAME}, 5, $hash->{NAME}." => Processing state $state timer $nexttimer nextstate:".$hash->{helper}{state};
	
	#Initalize next Timer for next state
	InternalTimer(gettimeofday()+$nexttimer, \&SPI_MAX31865_Execute, $hash,0) if ($nexttimer > 0);
	return undef;
}

sub SPI_MAX31865_Open(@) {
	my ($hash) = @_;

	my $spidev="/dev/spidev0.";
	my $device=AttrVal($hash->{NAME}, "device", 0);
	my $handler = undef;
	my $ret = sysopen($handler, $spidev.$device, O_RDWR);
	if ($ret != 1) { readingsSingleUpdate($hash, 'state', "Error opening SPI device",0); return undef;};

	my $mode=$SPI_MAX31865_Config{SPI_CFG}{SPI_MODE_1};	
	$mode = pack("L", $mode);
	$ret=ioctl($handler, $SPI_MAX31865_Config{SPI_MOD}{SPI_IOC_WR_MODE} , $mode) || -1;
	if ($ret==-1) { readingsSingleUpdate($hash, 'state', "SPI IOCTL error",0); return undef;};

	my $bits = pack("L", 8);
	$ret=ioctl($handler, $SPI_MAX31865_Config{SPI_MOD}{SPI_IOC_WR_BITS_PER_WORD}, $bits) || -1;
	if ($ret==-1) { readingsSingleUpdate($hash, 'state', "SPI IOCTL error",0); return undef;};
		
	my $SPI_freq=AttrVal($hash->{NAME}, "spi_frequency", 65536);
	my $speed = pack("L", $SPI_freq);
	$ret=ioctl($handler, $SPI_MAX31865_Config{SPI_MOD}{SPI_IOC_WR_MAX_SPEED_HZ}, $speed) || -1;
	if ($ret==-1) { readingsSingleUpdate($hash, 'state', "SPI IOCTL error",0); return undef;};

	return $handler
}

sub SPI_MAX31865_GetIOCMD ($) {
	my $arg = (1 << 30);
	$arg |= (($_[0]*32) << 16);
	$arg |= (107 << 8);
	return $arg;
}

sub SPI_MAX31865_InitConfig(@) {
	my ($hash) = @_;
	my $handler=SPI_MAX31865_Open($hash);
	return undef unless (defined($handler));
	my $data="\0"x8;
	my $ptr1 = unpack( 'L', pack( 'P', $data ) );
	my $struct;
	
	#define base config
	my $config=$SPI_MAX31865_Config{MAX_FLAGS}{CONFIG_1SHOT}
		|$SPI_MAX31865_Config{MAX_FLAGS}{CONFIG_BIAS}
		|$SPI_MAX31865_Config{MAX_FLAGS}{CONFIG_FAULTSTAT}
		|$SPI_MAX31865_Config{MAX_FLAGS}{CONFIG_FILT50HZ}
		|$SPI_MAX31865_Config{MAX_FLAGS}{MAX31865_CONFIG_24WIRE};

	#Set Basic Config, Bias & 1Shot
	$data = pack("CC",($SPI_MAX31865_Config{MAX_FLAGS}{CONFIG_REG} | 0x80),$config); #0x80 is write mode
	$struct = pack("QQLLSCCL", $ptr1, 0, 2,0,0, 8, 0, 0);			
	my $ret=ioctl($handler, SPI_MAX31865_GetIOCMD(1), $struct);
	if ($ret==-1) { readingsSingleUpdate($hash, 'state', "SPI IOCTL error",0);};
	close ($handler);
}

sub SPI_MAX31865_ReadData(@) {
	my ($hash, $sensor) = @_;
	my $handler=SPI_MAX31865_Open($hash);
	return undef unless (defined($handler));
	my $data="\0"x8;
	my $rep="\0"x8;
	my $ptr1 = unpack( 'L', pack( 'P', $data ) );
	my $ptr2 = unpack( 'L', pack( 'P', $rep ) );
	my $struct;
	
	$data = pack("CCC",$SPI_MAX31865_Config{MAX_FLAGS}{RTDMSB_REG},0,0);
	$struct = pack("QQLLSCCL", $ptr1, $ptr2, 3,0, 0, 8, 0, 0);			
	my $ret=ioctl($handler, SPI_MAX31865_GetIOCMD(1), $struct);
	
	my @reply=unpack("CCC",$rep);
	my $retdata=0;
	for(my $i=1; $i < 3; $i++) { #Ignore first byte, not sure why this extra byte is sent
		$retdata=($retdata<<8)+$reply[$i];
	}

	my $rtd_nominal=AttrVal($hash->{NAME}, "PT", 1000);
	
	my $corr=AttrVal($hash->{NAME}, "correction", 1.0);

	$retdata >>=1; 
	my $resistance = ($retdata/32768.0)*4.3*$rtd_nominal*$corr; #for PT1000: 4300Ohm, PT100:430Ohm -> PT*4.3

	my $Z1 = -$SPI_MAX31865_Config{RTD_A};
	my $Z2 = $SPI_MAX31865_Config{RTD_A} * $SPI_MAX31865_Config{RTD_A} - (4 * $SPI_MAX31865_Config{RTD_B});
	my $Z3 = (4 * $SPI_MAX31865_Config{RTD_B}) / $rtd_nominal;
	my $Z4 = 2 * $SPI_MAX31865_Config{RTD_B};
	my $temp = $Z2 + ($Z3 * $resistance);
	if ($temp>0) {
		$temp = (sqrt($temp) + $Z1) / $Z4;
	} else {$temp=0;}
	
	Log3 $hash->{NAME}, 5, $hash->{NAME}." => Reistance: $resistance , Temperature: $temp";
	my $temperature = sprintf( '%.' . AttrVal($hash->{NAME}, 'decimals', 1) . 'f', $temp 	); 
	readingsSingleUpdate($hash, 'temperature', $temperature,1) if (ReadingsVal($hash->{NAME},"temperature",0) != $temperature);
	readingsSingleUpdate($hash, 'state', "Ok",0);
	close($handler);
}

################################### 
sub SPI_MAX31865_Attr(@) {					#
 my ($command, $name, $attr, $val) = @_;
 my $hash = $defs{$name};
 my $msg = undef;

#Needs no IODev unless somebody will implement a basic SPI device some day
# if ($command && $command eq "set" && $attr && $attr eq "IODev") {
#		if ($main::init_done and (!defined ($hash->{IODev}) or $hash->{IODev}->{NAME} ne $val)) {
#			main::AssignIoPort($hash,$val);
#			my @def = split (' ',$hash->{DEF});
#			SPI_MAX31865_Init($hash,\@def) if (defined ($hash->{IODev}));
#		}
#	}
  if ($attr eq 'poll_interval') {
    if ( defined($val) ) {
      if ( looks_like_number($val) && $val >= 0) {
        RemoveInternalTimer($hash);
        InternalTimer(gettimeofday()+1, 'SPI_MAX31865_Execute', $hash, 0) if $val>0;
      } else {
        $msg = "$hash->{NAME}: Wrong poll intervall defined. poll_interval must be a number >= 0";
      }    
    } else {
      RemoveInternalTimer($hash);
    }
  }

  #check for correct values while setting so we need no error handling later
  foreach ('correction', 'SPI_frequency') {
	if ($attr eq $_) {
		if ( defined($val) ) {
			if ( !looks_like_number($val) || $val <= 0) {
				$msg = "$hash->{NAME}: ".$attr." must be a number > 0";
			}
		}
	}
  }
  return $msg;	
}
################################### 
sub SPI_MAX31865_Define($$) {			#
 my ($hash, $def) = @_;
 my @a = split("[ \t]+", $def);
 readingsSingleUpdate($hash, 'state', 'Defined',0);
 if ($main::init_done) {
    eval { SPI_MAX31865_Init( $hash, [ @a[ 2 .. scalar(@a) - 1 ] ] ); };
    return SPI_MAX31865_Catch($@) if $@;
  }
  return undef;
}
################################### 
sub SPI_MAX31865_Init($$) {				#
	my ( $hash, $args ) = @_;
	#my @a = split("[ \t]+", $args);
	my $name = $hash->{NAME};
	if (defined $args && int(@$args) != 0)	{
		return "Define: Wrong syntax. Usage:\n" .
		       "define <name> SPI_MAX31865";
	}

	readingsSingleUpdate($hash, 'state', 'Initialized',0);
	SPI_MAX31865_Set($hash, $name, "setfromreading");
	RemoveInternalTimer($hash);
	my $pollInterval = AttrVal($hash->{NAME}, 'poll_interval', 0)*60;
	InternalTimer(gettimeofday() + $pollInterval, 'SPI_MAX31865_Execute', $hash, 0) if ($pollInterval > 0);
	return;
}

################################### 
sub SPI_MAX31865_Catch($) {
	my $exception = shift;
	if ($exception) {
		$exception =~ /^(.*)( at.*FHEM.*)$/;
		return $1;
	}
	return undef;
}
################################### 
sub SPI_MAX31865_State($$$$) {			#reload readings at FHEM start
	my ($hash, $tim, $sname, $sval) = @_;
	#No persistant data needed, using only attributes
	return undef;
}
################################### 
sub SPI_MAX31865_Undef($$) {				#
	my ($hash, $name) = @_;
	RemoveInternalTimer($hash) if ( defined (AttrVal($hash->{NAME}, "poll_interval", undef)) ); 
	return undef;
}

1;

#Todo Write update documentation

=pod
=item device
=item summary reads temperatures from PT1000/PT100 sensors via SPI from the MAX31865 
=item summary_DE liest Temperaturen von PT1000/PT100 Sensoren via SPI vom MAX31865
=begin html

<a name="SPI_MAX31865"></a>
<h3>SPI_MAX31865</h3>
(en | <a href="commandref_DE.html#SPI_MAX31865">de</a>)
<ul>
	<a name="SPI_MAX31865"></a>
		Provides an interface to an MAX31865 A/D converter via SPI.<br>
		The SPI interface uses the standard Raspberry /dev/spidev0.0/1, so currently only 2 devices are supported simultaneously.
		Make sure SPI is enabled on the Raspberry and the device is correctly connected to MOSI,MISO,CLK and CE0/CE1.
		<br><br>
		<b>Limitations:</b><br><br>
		Initial version does not support the second SPI device available on Raspberry 2+.<br>
		No Auto_Mode (Continious read) supported.<br>
		No usage of own GPIO for CS supported.<br>
		<b>Features:</b><br>
		Read temperature from PT1000/PT100 in Celsius from spidev0.0 or spidev0.1 (two instances required to read both sensors).
		<br>
		<br>
	<a name="SPI_MAX31865Define"></a><br>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; SPI_MAX31865</code><br>
		No arguments. SPIDev is set by attribute<br>
		<br>
	</ul>

	<a name="SPI_MAX31865Set"></a>
	<b>Set</b>
	<ul>
		<code>set &lt;name&gt; &lt;Update&gt;</code><br><br>
			<ul>
			<li>Trigger a reading, restart timers<br>
			</ul>
		<br>
	</ul>

	<a name="SPI_MAX31865Attr"></a>
	<b>Attributes</b>
	<ul>
		<li>device<br>
			Defines which spidev to use <br>
			Default: 0, valid values: 0,1<br>
		</li>
		<br>
		<li>poll_interval<br>
			Set the polling interval in minutes to query a new reading from device<br>
			By setting this number to 0, the device can be set to manual mode (new readings only by "set update").<br>
			Default: -, valid values: decimal number<br>
		</li>
		<br>
		<li>PT<br>
			Type of attached PT sensor. Attention: This also sets the reference resistor accordingly. There are two versions of the device, one for PT1000 with a 4300 Ohm resistor and one for PT100 with a 430 Ohm resistor. 
			Since this cannot be mixed, the reference resistor is implicitly defined by choosing with PT is used.<br>
			Default: 1000, valid values: 1000,100<br>
		</li>	
		<br>
		<li>correction<br>
			Factor that is applied to the resistance reading before calculating the temperature. Can be used to calibrate the system.<br>
			Default: 1.0, valid values: float number<br>
		</li>
		<br>
		<li>decimals<br>
			Number of decimals (after the decimal point) for the temperature.<br>
			Default: 1, valid values: 0,1,2,3,4,5<br>
		</li>
		<br>
		<li>spi_frequency<br>
			Frequency used to communicate with SPI bus. It is recommended to use the same frequency for both devices.<br>
			Due to only transmitting only very low amount of data and the device taking 65ms to process, this setting should be irrelevant.<br>
			Default: 65536, valid values: number<br>
		</li>
		<br>
		<li><a href="#ignore">ignore</a></li>
		<li><a href="#do_not_notify">do_not_notify</a></li>
		<li><a href="#showtime">showtime</a></li>
	</ul>
	<br>
</ul>

=end html

=begin html_DE

<a name="SPI_MAX31865"></a>
<h3>SPI_MAX31865</h3>
(<a href="commandref.html#SPI_MAX31865">en</a> | de)
<ul>
	<a name="SPI_MAX31865"></a>
		Bitte englische Dokumentation verwenden.</b><br>
	<a name="SPI_MAX31865Define"></a><br>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; SPI_MAX31865</code><br>
		Alles weitere wird über Attribute definiert.<br>
	</ul>

	<a name="SPI_MAX31865Set"></a>
	<b>Set</b>
	<ul>
	</ul>

	<a name="SPI_MAX31865Attr"></a>
	<b>Attribute</b>
	<ul>
		<li>poll_interval<br>
			Aktualisierungsintervall aller Werte in Minuten.<br>
			Standard: -, g&uuml;ltige Werte: Dezimalzahl<br><br>
		</li>
		<li><a href="#ignore">ignore</a></li>
		<li><a href="#do_not_notify">do_not_notify</a></li>
		<li><a href="#showtime">showtime</a></li>
	</ul>
	<br>
</ul>

=end html_DE

=cut
