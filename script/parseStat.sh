#!/bin/bash

AllNodes=$1
Folder=$2
FetchName=$3
Good=false

for i in `seq 1 100`
do
Results=`sudo ./localScripts/getStat.sh "$1" $FetchName`
echo "Result is " "$Results"
if [[ $Results == *"badrpc"* ]]
then
    echo "Wrong format, try again!"
else
    Results=`cut -d "[" -f 2 <<< "$Results"`
    Results=`cut -d "]" -f 1 <<< "$Results"`
    break
fi
done

echo "$Results" >> $Folder/stat
