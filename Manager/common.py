#!/usr/bin/env python3
#This script prepares and launches the translator pipeline on the Tofino switch

import pexpect
import time
import datetime
import re

def getTime():
	return datetime.datetime.now()

def log(text):
	timestamp_str = getTime()
	fulltext = "%s\t %s" %(timestamp_str, text)
	
	print(fulltext)

#Converting inputs like 966.95kpps or 1MPPS to float with raw PPS
def strToPktrate(rate_str):
	rate_str = rate_str.lower()
	
	number = float(re.findall("[0-9]+\.[0-9]+|[0-9]+", rate_str)[0])
	
	order = str(re.findall("[km]?pps", rate_str)[0])
	
	#print(number)
	#print(order)
	#print()
	
	if order == "pps":
		return number
	elif order == "kpps":
		return number*1000
	elif order == "mpps":
		return number*1000000
	
	
	return None
