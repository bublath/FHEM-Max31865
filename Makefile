all:	spi_max31865

spi_max31865 :	spi_max31865.c
	cc -g spi_max31865.c -o spi_max31865 -I . -L . -lm

