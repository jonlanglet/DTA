# DTA - Collector
This directory contains code for the Collector component of DTA.

## Prerequisites
You need a server equipped with an RDMA-capable network card, supporting RoCEv2. 
The network card needs to be fully installed and ready for RDMA workloads.
We used a Mellanox Bluefield 2 DPU during development and evaluation.

## Setup
1. Compile the collector `gcc -o collector collector.cpp -lrdmacm -libverbs -lstdc++`
2. Disable iCRC verification on the network card (contact the manufacturer for support)
3. Ensure that the network card has a direct connection to the Translator

## Runtime
The collector should start first, before launching the translator.

1. Start the collector `sudo ./collector`

