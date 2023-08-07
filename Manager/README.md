# Direct Telemetry Access (DTA) - Manager
This directory contains code for the Direct Telemetry Access manager.

The manager is a central computer who is in charge of setting up, configuring, and running the tests.
This is meant to automate and simplify running DTA tests, and can be used as a guide on how the components are set up to work together

## Configuration
At the moment, the management scripts contain a lot of hard-coded hostnames, paths, etc.
Please iterate over the scripts and update these to match your testbed.

TODO: simplify by making this into a configuration file.

## Usage
You interact with the manager through a simple CLI menu.
Please just launch the manager on a machine (with connectivity to the machines in the testbed) through `./Manager.py`, and use the menu to set up and test DTA.

TODO: write a guide of example meny actions, and expected outputs. Also explain how they can manually start the collector if they want to inspect the data structures.
