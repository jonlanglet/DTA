# DTA - Reporter
This is an example telemetry-generating switch with DTA support.

The reporter presented here generates telemetry postcards containing placeholder data, to be queryable in a key/value storage using the source IP address as key.

Generation of a report is triggered both through change-detection, and for random packets even when a change is not detected.

Ingress performs change detection and triggers generation of a new packet (to be used for report-creation).
Egress transforms report-packets into DTA reports.

## Prerequisites
You need a Tofino switch, fully installed and operational.
We used the Barefoot SDE 9.7 during development and evaluation.

## Setup
1. Compile the Reporter pipeline [here](p4src/dta_reporter.p4)

## Runtime
1. Launch the compiled pipeline on the Tofino ASIC
2. Configure the ports
3. Launch the on-switch CPU component `$SDE/run_bfshell.sh -b <script> -i` (replace `<script>` with the path to [switch_cpu.py](switch_cpu.py), e.g., `~/projects/dta/reporter/switch_cpu.py`)
4. Send traffic through the reporter to generate DTA reports. For example, you can use the [pktgen.py](pktgen.py)
