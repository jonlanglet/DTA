# DTA - Translator
This directory contains code for the Translator component of DTA.

## Files
- [p4src](p4src/) contains the hardware pipeline for the translator.
- [init_rdma_connection.py](init_rdma_connection.py) is responsible for initiating RDMA connections. Should **not** be run manually.
- [inject_dta.py](inject_dta.py) injects a DTA report into the translator, useful to verify the functionality and troubleshoot the system.
- [pktgen.py](pktgen.py) injects a non-telemetry packet into the translator.
- [send_rdma_synthetic.py](send_rdma_synthetic.py) injects a (broken) RDMA packet into the translator.
- [switch_cpu.py](switch_cpu.py) is the switch-local controller. This 

## Prerequisites
You need a Tofino switch, fully installed and operational.
Please follow the setup guide in the repository root.

## Setup
1. Update the Translator pipeline [dta_translator.p4](p4src/dta_translator.p4) with correct MAC addresses for your server.
2. Reconfigure the pipeline as you prefer, through the built-in preprocessor directives.
3. Compile the Translator pipeline using the P4 compiler provided by the switch's SDE.
4. Update the port mapping in switch_cpu.py to match your cabling
5. Update the initial RDMA packets in [init_rdma_connection.py](init_rdma_connection.py)
6. Update the ports and IP addresses in [switch_cpu.py](switch_cpu.py) to match your testbed. These are the port IDs as seen in P4, and are switch-dependent.

## Runtime
The DTA translator will establish RDMA queue pairs with the DTA collector. 
Due to this, the collector must be configured and online before the translator CPU component is launched.

1. Launch the compiled pipeline on the Tofino ASIC
2. Configure the ports
3. Launch the on-switch CPU component `$SDE/run_bfshell.sh -b <script> -i` (replace `<script>` with the path to [switch_cpu.py](switch_cpu.py), e.g., `~/projects/dta/translator/switch_cpu.py`)

## Verify Functionality
If everything is set up correctly, the collector should have confirmed an established connection at its side after launching the on-switch CPU component.

To confirm full system functionality, use [inject_dta.py](inject_dta.py). This script will inject a DTA report into the translator from the translator's CPU, triggering RDMA generation and data insertion in the collector. 
Make sure that you update the destination IP address to match your collector, and the interface name to match the interface between the OS/CPU and ASIC.

## Troubleshooting
I recommend a few steps while troubleshooting the RDMA connection:
- Confirm that the RDMA_CM packets are received at the collector by inspecting the NIC counters. These counters can also hint at the underlying issue in your setup.
- Confirm that iCRC is disabled at the collector.
- Confirm that you can establish "normal" RDMA connections to the collector, from another "normal" RDMA NIC.
- Very that [init_rdma_connection.py](init_rdma_connection.py) is correctly modified. Dump the raw traffic during the initiation of a "normal" RDMA_CM connection, and between the translator and collector. Inspect these packets to see where in [init_rdma_connection.py](init_rdma_connection.py) you need to make modifications.

If you are unable (or able!) to solve your issue, please let me know and I will update this guide and/or provide assistance accordingly.

**Note:** [send_rdma_synthetic.py](send_rdma_synthetic.py) **is not meant to be used**, and should in most cases be ignored. It will **not** establish any RDMA connections as-is.