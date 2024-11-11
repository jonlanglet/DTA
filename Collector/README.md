# DTA - Collector
This directory contains code for the Collector component of DTA.

## Prerequisites
- A server equipped with an RDMA-capable rNIC, supporting RoCEv2.
- Installed, configured, and verified RDMA drivers ready work workloads.
- **Preferably** a direct link between the Translator-switch and the rNIC.

Please verify that the RDMA setup works before proceeding with the DTA installation. 
This can be done for example by connecting two RDMA-capable NICs, and using the `ib_send_bw` utility.

## Setup
1. Compile the collector `gcc -o collector collector.cpp -lrdmacm -libverbs -lstdc++`
2. Disable iCRC verification on the network card (contact the manufacturer for support)
3. Ensure that the network card has a direct connection to the Translator

## Runtime
The collector should start first, before launching the translator.

1. Start the collector `sudo ./collector`

