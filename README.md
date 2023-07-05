# DirectTelemetryAccess
![Overview](Overview.png)

This repository contains the code and helpful guides to set up an environment with Direct Telemetry Access.

See the sub-folders for details about setting up the various components.

## Components
This repository consists of several components, each located within their own subdirectories.

### Collector
[Collector/](Collector/) contains files for the DTA collector.
This component will reside on the collector server, and will host the memory data structures that the translator will write into.

### Generator
[Generator/](Generator/) contains files for the TReX traffic generator.

### Manager
[Manager/](Manager/) is a set of automation scripts for DTA that handles testbed setup and configuration by connecting to and running commands on the various DTA components.
While it is not an essential component for DTA, it greatly simplifies tests while also implicitly acting as documentation for the DTA system.

### Reporter
[Reporter/](Reporter/) is a DTA reporter switch. This switch can generate telemetry reports through DTA.

### Translator
[Translator/](Translator/) is a DTA translator switch. This switch will intercept DTA reports and convert these into RDMA traffic. It is in charge of establishing and managing RDMA queue-pairs with the collector server.


## Requirements
1. A fully installed Tofino switch
2. A server equipped with a RoCEv2-capable RDMA NIC, configured and ready for RDMA workloads
3. Optional: one additional server to act as a traffic generator

### Testbed
To produce the results from the paper, we had a testbed configured as follows:

![Testbed](Testbed.png)

## HowTo

### RDMA setup on the collector server
A working RDMA environment at the collector-server is essential in DTA.

1. Make sure that your NIC supports RDMA through RoCEv2. 
We used the NVIDIA Bluefield-2 DPU, and we can not guarantee success with other network cards. However, other RoCEv2-capable network cards where you can disable iCRC verification might work just as well.

2. Install and configure the necessary software and drivers.

3. Verify that the RDMA setup is valid. This can be done by connecting two servers together with RDMA-capable NICs for example through the `ib_send_bw` command.

### Tofino setup
Our DTA prototype is written for the Tofino-1 ASIC, specifically SDE version 9.7. Newer SDE versions are likely to work as well (possibly with minor tweaks to DTA)

1. Install the SDE and BSP according to the official documentation.

2. Verify that you can compile and launch P4 pipelines on the Tofino ASIC, and that you can successfully process network traffic.

### DTA setup
As previously mentioned, DTA consists of several components. You will at a minimum make sure that the translator and collector works

1. Essential: Compile and install the DTA [Translator/](Translator/).
2. Essential: Compile and install the DTA [Collector/](Collector/).
3. Recommended: Compile and install the DTA [Generator/](Generator/).
4. Recommended: Compile and install the DTA [Manager/](Manager/).
5. Optional: Compile and install the DTA [Reporter/](Reporter/).
