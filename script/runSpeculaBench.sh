#!/bin/bash
set -u
set -e
AllNodes=`cat script/allnodes`

if [ $# == 6 ]
then
    echo "Use default num for district, item and customer"
    MaxDistrict=10
    MaxItem=10000
    MaxCustomer=100
elif [ $# == 9 ]
then
    echo "MaxDistrict is" $7 ", MaxItem is "$8 ", MaxCustomer is "$9
    MaxDistrict=$7
    MaxItem=$8
    MaxCustomer=$9
else
    echo "Wrong usage: concurrent, accessMaster, accessSlave, do_specula, specula_length, folder, [num_district, num_item, num_customers]"
    exit
fi

#Params: nodes, cookie, num of dcs, num of nodes, if connect dcs, replication or not, branch
Time=`date +'%Y-%m-%d-%H%M%S'`
Folder=$6/$Time
mkdir $Folder
Tpcc="./basho_bench/examples/tpcc.config"
Load="./basho_bench/examples/load.config"
Ant="./antidote/rel/antidote/antidote.config"
./masterScripts/changeConfig.sh "$AllNodes" $Tpcc concurrent $1
./masterScripts/changeConfig.sh "$AllNodes" $Load concurrent 1
#Change Tpcc params
./masterScripts/changeConfig.sh "$AllNodes" $Tpcc max_district $MaxDistrict 
./masterScripts/changeConfig.sh "$AllNodes" $Tpcc max_item $MaxItem 
./masterScripts/changeConfig.sh "$AllNodes" $Tpcc max_customer $MaxCustomer 
#Change Load params
./masterScripts/changeConfig.sh "$AllNodes" $Load max_district $MaxDistrict 
./masterScripts/changeConfig.sh "$AllNodes" $Load max_item $MaxItem 
./masterScripts/changeConfig.sh "$AllNodes" $Load max_customer $MaxCustomer 
###
./masterScripts/changeConfig.sh "$AllNodes" $Tpcc duration 1 
./masterScripts/changeConfig.sh "$AllNodes" $Load duration 1 
./masterScripts/changeConfig.sh "$AllNodes" $Tpcc to_sleep 10000 
./masterScripts/changeConfig.sh "$AllNodes" $Load to_sleep 10000
./masterScripts/changeConfig.sh "$AllNodes" $Tpcc access_master $2
./masterScripts/changeConfig.sh "$AllNodes" $Tpcc access_slave $3
./masterScripts/changeConfig.sh "$AllNodes" $Ant do_specula $4
./masterScripts/changeConfig.sh "$AllNodes" $Ant do_repl true
./masterScripts/changeConfig.sh "$AllNodes" $Ant fast_reply true 
./masterScripts/changeConfig.sh "$AllNodes" $Ant specula_length $5 

./script/restartAndConnect.sh "$AllNodes"  antidote 
sleep 10
./script/parallel_command.sh "cd basho_bench && rm prep"  
./script/parallel_command.sh "cd basho_bench && sudo mkdir -p tests && sudo ./basho_bench examples/load.config"
./script/parallel_command.sh "cd basho_bench && sudo mkdir -p tests && sudo ./basho_bench examples/tpcc.config"
./script/gatherThroughput.sh $Folder
./script/copyFromAll.sh prep ./basho_bench/tests/current/ $Folder 
./script/copyFromAll.sh new-order_latencies.csv ./basho_bench/tests/current/ $Folder 
for N in $AllNodes
do
./script/parseStat.sh $N $Folder
done
./script/getAbortStat.sh `head -1 ./script/allnodes` $Folder 
echo $1 $2 $3 $4 $5 $6 > $Folder/config
