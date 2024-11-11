# Direct Telemetry Access (DTA)
![Overview](Overview.png)

This repository contains the code for Direct Telemetry Access.

Direct Telemetry Access is a peer-reviewed system for high-speed telemetry collection, capable of line-rate report ingestion.

The paper is available here: [ACM SIGCOMM](https://dl.acm.org/doi/10.1145/3603269.3604827) / [arXiv](https://arxiv.org/abs/2202.02270).

## Overview of Components
DTA is a system consisting of several components, each in their own directories.

### Reporter
[Reporter/](Reporter/) is a DTA reporter switch. 
This switch can generate telemetry reports through DTA.

### Translator
[Translator/](Translator/) is a DTA translator switch. 
This switch will intercept DTA reports and convert these into RDMA traffic. 
It is in charge of establishing and managing RDMA queue-pairs with the collector server.

### Collector
[Collector/](Collector/) contains files for the DTA collector.
This component will reside on the collector server, and will host the in-memory data aggregation structures that the translator will write telemetry reports into.

### Generator
[Generator/](Generator/) contains files for the TReX traffic generator.

### Manager
[Manager/](Manager/) is a set of automation scripts for DTA that handles testbed setup and configuration by connecting to and running commands on the various DTA components.
While the manager is not essential for DTA, it greatly simplifies tests while also indirectly acting as documentation for how to use the DTA system in this repository.


## Requirements
1. A fully installed and functional Tofino switch.
2. A server equipped with a RoCEv2-capable RDMA NIC, configured and ready for RDMA workloads.
3. Optional: one additional server to act as a traffic generator.
4. Cabling between the devices.

### NICs
DTA likely works with most RoCEv2-capable rNICs where you can disable iCRC verification.

It is so far confirmed to work with the following rNICs:
- ConnectX-6
- Bluefield-2 DPU (we used this)

Please let me know if you have tried other NICs, and I will update the list.

### Testbed
Our development/evaluation testbed was set up as follows:

![Testbed](Testbed.png)

If you change the cabling, update the [Translator](Translator/) accordingly.

## Installation
**The installation is complex. Make sure that you understand the components and workflow.**

As previously mentioned, DTA consists of several components. A working translator and collector are the base essentials.
Please refer to the individual component directoried for installation guides and tips.

1. Install the DTA [Collector](Collector/) **Essential**
2. Install the DTA [Translator](Translator/) **Essential**
3. Set up the traffic [Generator](Generator/) (Optional)
4. Set up the DTA [Manager](Manager/) (Optional)
5. Compile and install the DTA [Reporter](Reporter/) (Optional)

### Tofino setup
Our DTA prototype is written for the Tofino-1 ASIC, specifically running SDE version 9.7. 
Newer SDE versions most likely to work just as well (possibly with minor tweaks to the translator code)

1. Install the SDE and BSP according to official documentation from Intel and the board manufacturer.
2. Verify that you can compile and launch P4 pipelines on the Tofino ASIC, and that you can successfully process network traffic.
3. Modify the translator P4 code to generate RDMA packets with correct MAC addresses for the NIC (function `ControlCraftRDMA` in file [dta_translator.p4](Translator/p4src/dta_translator.p4))
4. **This step could prove difficult.** Modify the initial RDMA packets generated from the Translator CPU to be compatible with your network card (in file [init_rdma_connection.py](Translator/init_rdma_connection.py)), so that is can successfully establish new RDMA connections. I recommend establishing an RDMA connection to the collector NIC through normal means (using another machine) and dumping the first few packets to use as a template on how to establish an RDMA queue-pair. The current packets establish a queue-pair with our specific Mellanox Bluefield-2 DPU.
5. Update `--dir` value in init_rdma_connection.py and `metadata_dir` in switch.py to point to the same directory. This is where the RDMA metadata values (parsed from responses during the RDMA connection phase) are written. These values are later used to populate P4 M/A tables, required for generation of connection-specific RDMA packets from within the data plane

See [Translator/](Translator/) for more information.

## Running DTA
Once the DTA testbed is successfully set up, running it is relatively straightforward. We provide a set of automation scripts that could be useful, as well as a brief guide on how to do it manually.

### Using the DTA manager (automated)
The DTA manager automates starting DTA and performing simple tests.
Follow the guide in [Manager/](Manager/).

### Running DTA manually
Basically, you can manually do the tasks that the manager does automatically. If you get stuck, please refer to the manager scripts for hints.
1. Start the [Collector](Collector/)
2. Start the [Translator](Translator/)
3. Replay DTA traffic to the translator (for example using a [traffic generator](Generator/))
4. Analyze and print out the data structures at the collector (you should see how they are populated according to the DTA traffic intercepted by the translator).

## Integrating DTA into your telemetry system
Integrate DTA into your telemetry data flows to benefit from improved collection performance.

You need to update the telemetry-generating devices (reporters) to generate their telemetry reports with DTA headers (see [Reporter/](Reporter/) for an example).
Additionally, you need to update your centralized collector(s) to register the telemetry-storing data structures with RDMA to allow the translator(s) to access these regions (see [Collector/](Collector/) for an example).

It is also possible to craft new DTA primitives to better fit the specifics of your telemetry system. 
This could be a challenging process, but you can use our already implemented primitives as a reference on how to do this.


## Cite As
Please cite our work as follows:

```
@inproceedings{langlet2023DTA,
	author = {Langlet, Jonatan and Ben Basat, Ran and Oliaro, Gabriele and Mitzenmacher, Michael and Yu, Minlan and Antichi, Gianni},
	title = {Direct Telemetry Access},
	year = {2023},
	isbn = {9798400702365},
	publisher = {Association for Computing Machinery},
	address = {New York, NY, USA},
	url = {https://doi.org/10.1145/3603269.3604827},
	doi = {10.1145/3603269.3604827},
	booktitle = {Proceedings of the ACM SIGCOMM 2023 Conference},
	pages = {832–849},
	numpages = {18},
	keywords = {monitoring, telemetry collection, remote direct memory access},
	location = {New York, NY, USA},
	series = {ACM SIGCOMM '23}
}
```

## Need Help?
This repository is a prototype to demonstrate the capabilities and feasibility of DTA. 
However, the installation is not streamlined.

If you get stuck, please reach out to [Jonatan Langlet](https://langlet.io/) at `jonatan at langlet.io` and I will help out best I can.

I am also open to collaborations on DTA-adjacent research.
