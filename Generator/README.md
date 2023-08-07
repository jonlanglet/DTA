# DTA - Generator

We used TRex for traffic generation.
TRex either send traffic towards the reporter (so that the reporter generates DTA telemetry reports from user traffic), or to directly generate DTA reports going to the translator (which statefully translates these into RDMA going to the collector).

Download and install TRex according to their guide [here](https://trex-tgn.cisco.com/trex/doc/trex_manual.html#_download_and_installation) 

In this directory, you can find the scripts used to define the DTA traffic
