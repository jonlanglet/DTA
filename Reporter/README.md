# DTA Reporter
This directory contains code for the Reporter component of DTA.

## Prerequisites
You need a Tofino switch, fully installed and operational.
We used the Barefoot SDE 9.xx during development and evaluation.

## Setup
1. Compile the Reporter pipeline [here](p4src/dta_reporter.p4)

## Runtime
1. Launch the compiled pipeline on the Tofino ASIC
2. Configure the ports
3. Launch the on-switch CPU component `$SDE/run_bfshell.sh -b <script> -i` (replace `<script>` with the path to [switch_cpu.py](switch_cpu.py), e.g., `~/projects/dta/reporter/switch_cpu.py`)
