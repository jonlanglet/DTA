# DTA Collector
This directory contains code for the Collector component of DTA.

## Prerequisites
1. 

## Setup
1. Compile the collector module `gcc -o collector collector.cpp -lrdmacm -libverbs -lstdc++`
2. Disable iCRC verification on the network card

## Testbed Setup
The following image shows our current testbed setup:

![Tofino link configuration](../Figures/Testbed.png?raw=true "DTA Testbed")
