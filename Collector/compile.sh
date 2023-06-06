#!/bin/bash
#echo "Compiling RDMA server..."
#gcc -o server rdma_server.c rdma_common.c -lrdmacm -libverbs

#echo "Compiling RDMA client..."
#gcc -o client rdma_client.c rdma_common.c -lrdmacm -libverbs

echo "Compiling (old) DTA Collector..."
gcc -o collector collector_old.c rdma_common.c -lrdmacm -libverbs

echo "Compiling (new, incomplete) DTA Collector..."
gcc -o collector_new collector.cpp -lrdmacm -libverbs -lstdc++


