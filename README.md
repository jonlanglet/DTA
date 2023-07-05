# DirectTelemetryAccess
![Overview](Overview.png)

This repository contains the code and helpful guides to set up an environment with Direct Telemetry Access.

See the sub-folders for details about setting up the various components.

## Requirements
1. A fully installed Tofino switch
2. A RoCEv2-capable RDMA NIC installed in a switch, configured and ready for RDMA workloads

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

## Testbed Setup
To produce the results from the paper, we had a testbed configured as follows:

![Testbed](Testbed.png)
