/*
 * SPI MAX31865 temperature reading utility 
 *
 * Wiring:
 * Connect your MAX31865 SPI Device to the Raspberry PI
 * SD1 -> MOS1 (physical PIN 19)
 * SD0 -> MOS0 (physical PIN 21)
 * CLK -> SCLK (physical PIN 23)
 * CS -> CE0 (physical PIN 24) or CE1 (physical PIN 26)
 *
 * Supports two parallel devices (0 on CE0 and 1 on CE1)
 * No support for additional GPIOs
 * Tested with a PT1000 using a max31865 board with a 1kOhm resistor and jumpered for 2-wire
 *
 * calibrate with another temperature reading device and adjust corr to show the correct temperature
 * For PT100 change the resistor definitions (see below, not tested)
 *
 * Open questions:
 * - reads seems to be trailed by one NULL byte, so reading 8bit is rx[1] and reading 16bit is rx[1]*256+rx[2]
 * - to simplify things I'm setting all configs in one go, not sure if that is valid
 * - Values seem to come delayed (like always getting the previous reading) - not a killer for my application but for sure something to fix (maybe related to way I set configs?)
 *
 * compile with:
 * cc spi_max31865.c -o spi_max31865 -lm
 *
 * usage:
 * ./spi_max31865 0
 * to read temperature from "/dev/spidev0.0"
 * Reading from an unconnected SPI device will still raise no error, but give -246 degrees as output
 *
 * make sure SPI is enabled 
 * - not blacklisted in /etc/modprobe.d/raspi-blacklist.conf
 * - "dtparam=spi=on" is set in /boot/config.txt
 * 
 * Based on linux/tools/spi/spidev_test.c
 * and adafruit_max31865.py
 */

#include <stdint.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <getopt.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/types.h>
#include <linux/spi/spidev.h>

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

#define MAX31865_CONFIG_REG 0x00
#define MAX31865_CONFIG_BIAS 0x80
#define MAX31865_CONFIG_MODEAUTO 0x40
#define MAX31865_CONFIG_MODEOFF 0x00
#define MAX31865_CONFIG_1SHOT 0x20
#define MAX31865_CONFIG_3WIRE 0x10
#define MAX31865_CONFIG_24WIRE 0x00
#define MAX31865_CONFIG_FAULTSTAT 0x02
#define MAX31865_CONFIG_FILT50HZ 0x01
#define MAX31865_CONFIG_FILT60HZ 0x00
#define MAX31865_RTDMSB_REG 0x01
#define MAX31865_RTDLSB_REG 0x02
#define MAX31865_HFAULTMSB_REG 0x03
#define MAX31865_HFAULTLSB_REG 0x04
#define MAX31865_LFAULTMSB_REG 0x05
#define MAX31865_LFAULTLSB_REG 0x06
#define MAX31865_FAULTSTAT_REG 0x07
#define MAX31865_FAULT_HIGHTHRESH 0x80
#define MAX31865_FAULT_LOWTHRESH 0x40
#define MAX31865_FAULT_REFINLOW 0x20
#define MAX31865_FAULT_REFINHIGH 0x10
#define MAX31865_FAULT_RTDINLOW 0x08
#define MAX31865_FAULT_OVUV 0x04
#define RTD_A 3.9083e-3
#define RTD_B -5.775e-7

static void pabort(const char *s)
{
	perror(s);
	abort();
}

/* Eigentlich müsste CS egal sein (einfach auf low, damit die Kommunikation aktiv wird
   Wenn man das Python Beispiel laufen lässt, dann zeigt sich aber:
   - Wenn CS einfach auf GND gezogen oder nicht verbunden ist, kommen seltsame ergebnisse
      -242.020 Grad auf low oder leer (selbiges auch ohne CLK,MOS1 oder MOS0 oder ganz ohne VCC - ohne GND gehts es aber)
	  988.792 Grad auf high
	  
	Problem nach wie vor: Wie bindet am CS in diese Beispielprogram ein
*/

static uint8_t mode = SPI_MODE_1;
static uint8_t bits = 8;
static uint8_t lsb = 0;
static uint32_t speed = 65536;
static uint16_t delay;

int devID=0;
int rtd_nominal = 1000.0; //For boards with 1kOhm resistor to measure PT1000 - for 100Ohm boards for PT100 change to 100
int ref_resistor = 4300.0;  //For PT100 change to 430
int wires=2; 
int filter_frequency=60;
float corr=1.0; //Correct error to calibrate resistor/temperature reading

void print_usage(const char *prog)
{
	printf("Usage: %s DeviceID\n", prog);
	exit(1);
}

void parse_opts(int argc, char *argv[])
{
	if (argc<2) {
			print_usage(argv[0]);
	}

	int dev=atoi(argv[1]);

	if (argc>2) {
		corr=atof(argv[2]);
	}
	
	if (dev<0 | dev>1){
			print_usage(argv[0]);
	}
	
	devID=dev;
}

int main(int argc, char *argv[])
{
	int ret = 0;
	int fd;
	int config= 0;
	char device[] = "/dev/spidev0.x";

    uint8_t tx[8];
    uint8_t rx[8];

    struct spi_ioc_transfer tr;
	memset(&tr, 0, sizeof(tr));

	tr.tx_buf = (unsigned long)tx;
	tr.rx_buf = (unsigned long)rx;
	tr.len = ARRAY_SIZE(tx);
	tr.delay_usecs = delay;

	parse_opts(argc, argv);

	sprintf(device,"/dev/spidev0.%i",devID);

	fd = open(device, O_RDWR);
	if (fd < 0)
		pabort("can't open device");

	/*
	 * spi mode
	 */
	unsigned long command=SPI_IOC_WR_MODE;
	printf("SPI_IOC_WR_MODE:%x\n",SPI_IOC_WR_MODE);
	printf("SPI_IOC_RD_MODE:%x\n",SPI_IOC_WR_MODE);
	printf("SPI_IOC_RD_BITS_PER_WORD:%x\n",SPI_IOC_RD_BITS_PER_WORD);
	printf("SPI_IOC_WR_BITS_PER_WORD:%x\n",SPI_IOC_WR_BITS_PER_WORD);
	printf("SPI_IOC_RD_MAX_SPEED_HZ%x\n",SPI_IOC_RD_MAX_SPEED_HZ);
	printf("SPI_IOC_WR_MAX_SPEED_HZ%x\n",SPI_IOC_WR_MAX_SPEED_HZ);
	printf("SPI_IOC_RD_MODE32%x\n",SPI_IOC_RD_MODE32);
	printf("SPI_IOC_WR_MODE32%x\n",SPI_IOC_WR_MODE32);
	printf("SPI_IOC_MESSAGE(1)%x\n",SPI_IOC_MESSAGE(1));
	printf("SPI_IOC_MESSAGE(2)%x\n",SPI_IOC_MESSAGE(2));
	printf("SPI_IOC_MESSAGE(3)%x\n",SPI_IOC_MESSAGE(3));
	
	ret = ioctl(fd, SPI_IOC_WR_MODE, &mode);
	if (ret == -1)
		pabort("can't set spi mode");
	/*
	 * bits per word
	 */
	
//	ret = ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits);
//	if (ret == -1)
//		pabort("can't set bits per word");
	/*
	 * max speed hz
	 */
	ret = ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed);
	if (ret == -1)
		pabort("can't set max speed hz");

	tx[0]=MAX31865_CONFIG_REG & 0xff; //read mode
	tx[1]=0;
	tx[2]=0;
	ret = ioctl(fd, SPI_IOC_MESSAGE(1), &tr);
	if (ret == -1)
		pabort("can't send spi message");

	//printf("Initial Config:0x%x\n",rx[1]);  
	config=rx[1];

	//Clear Faults, Set Bias, Set 1Shot
	tx[0]=(MAX31865_CONFIG_REG | 0x80) & 0xff; //0x80 is write mode
	tx[1]=(config&~0x2c)|MAX31865_CONFIG_FAULTSTAT|MAX31865_CONFIG_24WIRE|MAX31865_CONFIG_1SHOT|MAX31865_CONFIG_BIAS & 0xff;
	tx[2]=0;
	ret = ioctl(fd, SPI_IOC_MESSAGE(1), &tr);
	usleep(65);
	ret = ioctl(fd, SPI_IOC_MESSAGE(1), &tr); // Trigger 2 times to eliminate old readings
	if (ret == -1)
		pabort("can't send spi message");
	usleep(100);

	//Read RTD resistor data
	tx[0]=MAX31865_RTDMSB_REG & 0x7f; 
	tx[1]=0;
	tx[2]=0;
	ret = ioctl(fd, SPI_IOC_MESSAGE(1), &tr);
	if (ret == -1)
		pabort("can't send spi message");

	printf("Read:0x%x 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x 0x%x\n",rx[0],rx[1],rx[2],rx[3],rx[4],rx[5],rx[6],rx[7]);  // Why is the configuration in rx[1] and rx[0] is 0 ?

	int retdata=(rx[1]<<8)+rx[2]; // Why is the data in rx[1]+rx[2] - Shouldn't it be in rx[0] and rx[1]

	retdata >>=1; //remove fault bit
	float resistance = (retdata/32768.0)*ref_resistor*corr;
	
    float Z1 = -RTD_A;
    float Z2 = RTD_A * RTD_A - (4 * RTD_B);
    float Z3 = (4 * RTD_B) / rtd_nominal;
    float Z4 = 2 * RTD_B;
    float temp = Z2 + (Z3 * resistance);
    temp = (sqrt(temp) + Z1) / Z4;
	
	printf("%3.2f\n",temp);

/* Alternative calculation method for temperature 

    resistance /= rtd_nominal;
    resistance *= 100;
	
    float rpoly = resistance;
    temp = -242.02;
    temp += 2.2228 * rpoly;
    rpoly *= resistance;
    temp += 2.5859e-3 * rpoly;
    rpoly *= resistance;
    temp -= 4.8260e-6 * rpoly;
    rpoly *= resistance;
    temp -= 2.8183e-8 * rpoly;
    rpoly *= resistance;
    temp += 1.5243e-10 * rpoly;
	printf("%3.2f\n",temp);	

*/


	close(fd);

	return ret;
}
