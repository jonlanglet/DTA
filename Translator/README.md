# DTA - Translator
This directory contains code for the Translator component of DTA.

## Prerequisites
You need a Tofino switch, fully installed and operational.
Please follow the setup guide in the repository root.

## Setup
1. Compile the Translator pipeline [here](p4src/dta_translator.p4)
2. Update the port mapping in switch_cpu.py to match your cabling
3. Update the initial RDMA packets in init_rdma_connection.py
4. ...

## Runtime
1. Launch the compiled pipeline on the Tofino ASIC
2. Configure the ports
3. Launch the on-switch CPU component `$SDE/run_bfshell.sh -b <script> -i` (replace `<script>` with the path to [switch_cpu.py](switch_cpu.py), e.g., `~/projects/dta/translator/switch_cpu.py`)
4. ...
