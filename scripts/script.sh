#!/bin/bash
START_TIME=$(date +%s)

##### ARGUMENTS ######
CHANNEL_NAME="$1"
CHANNELS="$2"
CHAINCODES="$3"
ENDORSERS="$4"
TX="$5"

##### SET DEFAULT VALUES #####
: ${CHANNEL_NAME:="mychannel"}
: ${CHANNELS:="1"}
: ${CHAINCODES:="1"}
: ${ENDORSERS:="4"}
: ${TX:="1"}

##### TUNABLE PARAMETERS #####
QTIMEOUT=30
CHAINCODE_NAME="mycc"
USE_CONCURRENT_JOBS="true"
INSTANTIATION_PEER=0
VERBOSE_LEVEL=3

# Set VERBOSE_LEVEL to higher numbers to see more logs from this script.
# e.g. Set to "2" to show all logs in categories LOG0,LOG1,LOG2.
# Optionally: get more logs from the docker container cli/orderer/peers by editing env vars
# such as CORE_DEBUG_LEVEL in ../docker-compose.yaml and ../peer-base/peer-base.yaml

##### GLOBALS ######

LOG0=0
LOG1=1
LOG2=2
LOG3=3
LOG4=4
LOG5=5
# high-level status logs
LOG_PROGRESS=$LOG1
# status timing logs for each section; most useful when running in non-concurrent setting, to gather timing estimates
LOG_TIMING=$LOG2
# success logs for every invoke and query; (Failure logs will always be printed, regardless of VERBOSE_LEVEL setting)
LOG_EACH_ACTION=$LOG3
# use this or higher numbers for even more detail for debugging specific areas
LOG_DETAIL=$LOG4

JOIN_RETRY_COUNTER=0
JOIN_RETRY_MAX=5

INVOKE_DONE_FILE=done_invoke.txt
QUERY_DONE_FILE=done_query.txt
TOTALDIMENSIONS=$(( $CHANNELS * $CHAINCODES * $ENDORSERS ))
TOTALINVOKES=$(( $TX * $TOTALDIMENSIONS ))
INVOKEACTION="invoke"
QUERYACTION="query"
VERIFYACTION="verify"
IERRORCOUNT=0
IMATCHCOUNT=0
QMATCHCOUNT=0
QERRORCOUNT=0
MORETEXTDATA="_WATSON!_We_have_achieved_hyperledger_fabric_consensus!"

# These values could be overridden by setGlobals, and locally in individual functions
CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/orderer/localMspConfig
CORE_PEER_LOCALMSPID="OrdererMSP"





printArgs() {
        log "printArgs for this $0 :
 Channel Name prefix               $CHANNEL_NAME
 Total Channels                    $CHANNELS
 Chaincodes per channel            $CHAINCODES
 Total Endorser Peers              $ENDORSERS
 Retry Timeout secs for query      $QTIMEOUT
 Transaction Multiplier            $TX
 Chaincode Name prefix             $CHAINCODE_NAME
 VERBOSE_LEVEL                     $VERBOSE_LEVEL
 USE_CONCURRENT_JOBS               $USE_CONCURRENT_JOBS
"  $LOG_PROGRESS
}

getCounts() {
        QMATCHCOUNT=`grep -c 'done' $QUERY_DONE_FILE`
        QERRORCOUNT=`grep -c 'done query error' $QUERY_DONE_FILE`
        IMATCHCOUNT=`grep -c 'done invoke pass' $INVOKE_DONE_FILE`
        IERRORCOUNT=`grep -c 'done verify error' $INVOKE_DONE_FILE`
}

done_action() {
        if test "$1" = "$QUERYACTION" ; then
                # query results
                echo -e "done $1 $2" >> $QUERY_DONE_FILE
        else
                # results from setup or invokes
                echo -e "done $1 $2" >> $INVOKE_DONE_FILE
        fi
}

log() {
        # First arg is the string to print. 2nd arg is the loglevel for this item.
        local loglevel=0
        test "$2" != "" && let loglevel=$2
        test "$VERBOSE_LEVEL" -ge "$loglevel" && echo -e "=== $(($(date +%s)-START_TIME))s: $1"
}

logsleep() {
        log "sleep $1 ... $2" $LOG_TIMING
        sleep "$1"
}

verifyResult() {
        if [ $1 -ne 0 ] ; then
                done_action "$VERIFYACTION" "error" "$2
 !!! ERROR : FAILED to execute full test scenario !!! (exited on error)"
                exit 1
        fi
}

setGlobals() {
        CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peer/peer$1/localMspConfig
        CORE_PEER_ADDRESS=peer$1:7051
        if [ $1 -eq 0 -o $1 -eq 1 ] ; then
                CORE_PEER_LOCALMSPID="Org0MSP"
        else
                CORE_PEER_LOCALMSPID="Org1MSP"
        fi
}

createChannel() {
        CHANNEL_NUM=$1
        peer channel create -o orderer:7050 -c $CHANNEL_NAME$CHANNEL_NUM -f crypto/orderer/channel$CHANNEL_NUM.tx >&log.txt
        res=$?
        #log "$(cat log.txt)" "$LOG_DETAIL"
        verifyResult $res "Channel creation with name \"$CHANNEL_NAME$CHANNEL_NUM\" has failed
$(cat log.txt)"
        log "Channel \"$CHANNEL_NAME$CHANNEL_NUM\" is created successfully" $LOG_PROGRESS
}

createChannels() {
        log "Create all $CHANNELS channels ..."
        for (( ch=0; $ch<$CHANNELS; ch++))
        do
                createChannel $ch
        done
}

## Sometimes Join takes time hence RETRY atleast for 5 times
joinWithRetry() {
        for (( i=0; $i<$CHANNELS; i++))
        do
                peer channel join -b $CHANNEL_NAME$i.block  >&log.txt
                res=$?
                #log "$(cat log.txt)" "$LOG_DETAIL"
                if [ $res -ne 0 -a $JOIN_RETRY_COUNTER -lt $JOIN_RETRY_MAX ]; then
                        JOIN_RETRY_COUNTER=` expr $JOIN_RETRY_COUNTER + 1`
                        logsleep 2 "PEER$1 failed to join the channel 'mychannel$i'; retrying"
                        joinWithRetry $1
                else
                        JOIN_RETRY_COUNTER=0
                fi
                verifyResult $res "After $JOIN_RETRY_MAX attempts, PEER$ch has failed to Join the Channel
$(cat log.txt)"
                log "PEER$1 joined on the channel \"$CHANNEL_NAME$i\"" $LOG_PROGRESS
        done
}

joinChannel() {
        PEER=$1
        setGlobals $PEER
        log "Joining PEER$PEER on all channels" $LOG_PROGRESS
        joinWithRetry $PEER
        log "PEER$PEER joined on $CHANNELS channel(s)" $LOG_PROGRESS
}

joinChannels() {
        log "Join all $ENDORSERS peers to all $CHANNELS channels ..."
        for (( peer=0; $peer<$ENDORSERS; peer++))
        do
                joinChannel $peer
        done
}

installChaincodes() {
        log "Install all $CHAINCODES chaincodes on all $ENDORSERS peers ..."
        for (( i=0; $i<$ENDORSERS; i++))
        do
                for (( cc=0; $cc<$CHAINCODES; cc++))
                do
                        PEER=$i
                        setGlobals $PEER
                        peer chaincode install -n $CHAINCODE_NAME$cc -v 1 -p github.com/hyperledger/fabric/examples/chaincode/go/newkeyperinvoke >&log.txt
                        res=$?
                        #log "Install Result: $(cat log.txt)" "$LOG_DETAIL"
                        verifyResult $res "Chaincode '$CHAINCODE_NAME$cc' installation on remote peer PEER$PEER has Failed
$(cat log.txt)"
                        log "Chaincode '$CHAINCODE_NAME$cc' is installed on remote peer PEER$PEER" $LOG_PROGRESS
                        done
                log "Installed $CHAINCODES Chaincodes on PEER$i"
        done
}

instantiateChaincodes() {
        PEER=$1
        setGlobals $PEER
        log "Instantiating all $CHAINCODES chaincodes on all $CHANNELS channels, using peer $PEER ..."
        for (( i=0; $i<$CHANNELS; i++))
        do
                for (( cc=0; $cc<$CHAINCODES; cc++))
                do
                        peer chaincode instantiate -o orderer:7050 -C $CHANNEL_NAME$i -n $CHAINCODE_NAME$cc -v 1 -c '{"Args":[""]}' -P "OR('Org0MSP.member','Org1MSP.member')" >&log.txt
                        res=$?
                        #log "Instantiate Result: $(cat log.txt)" "$LOG_DETAIL"
                        verifyResult $res "Chaincode '$CHAINCODE_NAME$cc' instantiation on PEER$PEER on channel '$CHANNEL_NAME$i' failed
$(cat log.txt)"
                        log "Chaincode Instantiation $CHAINCODE_NAME$cc on channel $CHANNEL_NAME$i on PEER$PEER successful" $LOG_PROGRESS
                done
                log "Instantiated $CHAINCODES Chaincodes on channel $CHANNEL_NAME$i on PEER$PEER"
        done
        # Increase the sleeptime if you see this error for first invoke
        # (when you enable log level LOG_DETAIL as used by chaincodeInvoke:  $(cat ${mytxt})" "$LOG_DETAIL")
        # because one way it can be seen is if the instantiation is not completed in the peer:
        # "Error endorsing invoke: rpc error: code = 2 desc = failed to obtain cds for mycc0 - transaction not found mycc0/mychannel0"
        #logsleep "$(( $CHAINCODES * 10 + 20 ))" "after instantiations"
        logsleep 20 "after instantiations"
}

chaincodeInvoke() {
        # ARGS: $channel_num $chain_num $peer_num $tx_id
        local channel_num=$1
        local chain_num=$2
        local peer_num=$3
        local tx_id=$4
        local key_value=$CHANNEL_NAME$channel_num$CHAINCODE_NAME$chain_num"PEER"$peer_num"TX"$tx_id
        local mytxt=${key_value}_i_log.txt
        local msporg="Org1MSP"
        if [ $peer_num -eq 0 -o $peer_num -eq 1 ] ; then
                msporg="Org0MSP"
        fi

        #log "Invoking $key_value" $LOG_EACH_ACTION

    # force errors on peer2 by skipping it - for testing
    # if [ $peer_num -ne 2 ] ; then
        # Cannot call setGlobals here or it might break concurrency; so set args on command line.
        CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peer/peer$peer_num/localMspConfig CORE_PEER_ADDRESS=peer$peer_num:7051 CORE_PEER_LOCALMSPID=$msporg peer chaincode invoke -o orderer:7050  -C $CHANNEL_NAME$channel_num -n $CHAINCODE_NAME$chain_num -c "{\"function\":\"$INVOKEACTION\",\"Args\":[\"put\", \"$key_value\",\"$key_value$MORETEXTDATA\"]}" >&${mytxt}
        res=$?
        # $mytxt log file contains nothing, if all goes well:
        #log "$(cat ${mytxt})" "$LOG_DETAIL"
        verifyResult $res "$INVOKEACTION execution failed on $key_value
$(cat ${mytxt})"
        log "Invoke transaction successful: $key_value" $LOG_EACH_ACTION
        done_action "$INVOKEACTION" "pass" "$key_value"
    #   fi
}

chaincodeQuery() {
        local channel_num=$1
        local chain_num=$2
        local peer_num=$3
        local tx_id=$4
        local key_value=$CHANNEL_NAME$channel_num$CHAINCODE_NAME$chain_num"PEER"$peer_num"TX"$tx_id
        local expected_value=$key_value$MORETEXTDATA
        local qVALUE=""
        local mytxt=${key_value}_q_log.txt
        local rc=1
        local starttime=$(date +%s)
        local msporg="Org1MSP"
        if [ $peer_num -eq 0 -o $peer_num -eq 1 ] ; then
                msporg="Org0MSP"
        fi

        log "Querying $key_value" $LOG_EACH_ACTION
        # continue to poll until we either get a successful response, or reach QTIMEOUT
        reattempts=0
        while test "$(($(date +%s)-starttime))" -lt "$QTIMEOUT" -a $rc -ne 0
        do
                CORE_PEER_MSPCONFIGPATH=/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peer/peer$peer_num/localMspConfig CORE_PEER_ADDRESS=peer$peer_num:7051 CORE_PEER_LOCALMSPID="$msporg" peer chaincode query -C $CHANNEL_NAME$channel_num -n $CHAINCODE_NAME$chain_num -c "{\"function\":\"$INVOKEACTION\",\"Args\":[\"get\",\"$key_value\"]}" >& ${mytxt}
                test $? -eq 0 && qVALUE=$(cat ${mytxt} | awk '/Query Result/ {print $NF}')
                test "$qVALUE" = "$expected_value" && let rc=0
                if test $rc -ne 0 ; then
                        if test $reattempts -eq 0 ; then
                                log "initial query of key $key_value returned value '$qVALUE' != expected value '$expected_value'; retry up to max timeout $QTIMEOUT secs" $LOG_TIMING
                                reattempts=$(( $reattempts + 1 ))
                        fi
                        sleep 1
                fi
        done
        if test $rc -eq 0 ; then
                log "Query successful: $key_value after $reattempts secs" $LOG_EACH_ACTION
                done_action "$QUERYACTION" "pass" "$key_value"
        else
                # $mytxt file contains: the query result AND ... nothing else unless error occurs
                done_action "$QUERYACTION" "error" "$key_value"
                cat ${mytxt}
                printSummary "!!!!!!!!!! Query result on PEER$peer_num is INVALID !!!!!!!!!!
 query key:      '$key_value'
 expected value: '$expected_value'
 received value: '$qVALUE'
 !!! ERROR : FAILED to execute full test scenario !!! (exited on query error)"
                exit 1
        fi
}

action_tx_loop() {
        # ARGS: $peer_num $myaction $transactions
        local peer_num=$1
        local myaction="$2"
        local transactions=$3
        local cc=0
        local ch=0
        local tx_id=0
        local start_with_tx_id=0
        test $transactions -gt 1 && let start_with_tx_id=1

        for (( tx_id=$start_with_tx_id ; $tx_id<$transactions ; tx_id++ ))
        do
                for (( ch=0 ; $ch<$CHANNELS ; ch++ ))
                do
                        for (( cc=0 ; $cc<$CHAINCODES ; cc++ ))
                        do
                                if [ "$myaction" = "$INVOKEACTION" ] ; then
                                        chaincodeInvoke $ch $cc $peer_num $tx_id
                                        if [ $tx_id -eq 0 -a $ch -eq 0 -a $peer_num -ne $INSTANTIATION_PEER ]; then
                                                # Every time we enter action_tx_loop (for each peer, -
                                                # except the peer where instantiations occurred already),
                                                # for the first transaction (should be the invokes)
                                                # on each channel, for every chaincodes, sleep extra time
                                                # to allow peer to deploy locally (retrieve/sync state info).
                                                # It takes at least 12 secs to deploy/sync, and let's give it
                                                # ANOTHER several secs to catchup on any queued msgs.
                                                logsleep 10 "allow extra time to get this new chaincode ${CHAINCODE_NAME}${cc} running on this peer $peer_num, before sending more txs which can pile up too quickly and lead to grpc errors on this machine"
                                        fi
                                else
                                        chaincodeQuery $ch $cc $peer_num $tx_id
                                fi
                                #fi
                        done
                done
        done
}

loop_through_all() {
        local myaction="$1"

        if test $TX -gt 0 ; then
                # serially take care of the first TX on every peer/channel/chaincode, to allow time for sync
                log "Sending 1 '$myaction' tx proposals on all channels/chaincodes/peers"
                local start1time=$(date +%s)
                for (( peer_num=0; $peer_num<$ENDORSERS; peer_num++))
                do
                        action_tx_loop $peer_num $myaction 1
                done
                log "action=$myaction serial execution time for FIRST transactions ($TOTALDIMENSIONS=peer*chan*cc) = $(($(date +%s)-start1time)) secs" $LOG_TIMING
        fi

        if test $TX -gt 1 ; then
                # Concurrently generate remaining transactions, using one background task per peer,
                # for each peer to send all the specified TX transactions to each channel/chaincode.
                log "Sending $(( $TX - 1 )) '$myaction' tx proposals on all channels/chaincodes; $USE_CONCURRENT_JOBS=USE_CONCURRENT_JOBS per peer"
                local starttime=$(date +%s)
                for (( peer_num=0; $peer_num<$ENDORSERS; peer_num++))
                do
                        if [ $USE_CONCURRENT_JOBS = "true" ] ; then
                                (action_tx_loop $peer_num $myaction $TX)&
                        else
                                action_tx_loop $peer_num $myaction $TX
                        fi
                done
                if [ "$USE_CONCURRENT_JOBS" != "true" ] ; then
                        log "action=$myaction serial execution time for $(( ($TX - 1) * $TOTALDIMENSIONS )) transactions = $(($(date +%s)-starttime)) secs" $LOG_TIMING
                fi
        fi
}

printSummary() {
        getCounts
        FINAL_RESULT_MESSAGE="FINAL RESULT: TEST PASSED"
        if [ $QMATCHCOUNT -ne $TOTALINVOKES ] ; then
                FINAL_RESULT_MESSAGE="FINAL RESULT: TEST FAILED !!!!!!!!!!"
                #cat $INVOKE_DONE_FILE
                #sort $QUERY_DONE_FILE
        fi
        printArgs
        log "printSummary:
 $1
 Expected Total Transactions       $TOTALINVOKES
 Expected TX per peer subtotal     $(( $TX * $CHANNELS * $CHAINCODES ))
 Expected TX per channel subtotal  $(( $TX * $CHAINCODES * $ENDORSERS))
 Query successes                   $QMATCHCOUNT
 Query errors                      $QERRORCOUNT
 Invoke successes                  $IMATCHCOUNT
 Invoke errors                     $IERRORCOUNT
 Total Elapsed execution time      $(($(date +%s)-START_TIME)) secs
 $FINAL_RESULT_MESSAGE
"
}





############################## MAIN THREAD START HERE ##############################

rm $INVOKE_DONE_FILE $QUERY_DONE_FILE &>/dev/null
touch $INVOKE_DONE_FILE $QUERY_DONE_FILE

printArgs

createChannels

joinChannels

installChaincodes

# use peer 0 to instantiate all chaincodes on all channels
instantiateChaincodes $INSTANTIATION_PEER

#Invokes
START_TIME_INVOKE=$(date +%s)
loop_through_all "$INVOKEACTION"
logsleep 2 "wait minimum for batchtimeout (default=2)"
getCounts
# if invokes are not all done then wait.
while test $TOTALINVOKES -ne $IMATCHCOUNT
do
        # If errors occurred then exit.
        # If there was a setup failure, during sequential steps, the script already
        # would have exited before sending any invokes (and would not get here).
        # If there has been an Invoke failure, then the associated background job
        # would have exited (after writing an error to file), but main thread still
        # reaches this point; we can check the errorfile if an invoke error occurred.
        verifyResult $IERRORCOUNT "EXIT MAIN THREAD DUE TO INVOKE ERROR"
        logsleep 10 "more invokes ... IMATCHCOUNT = $IMATCHCOUNT / $TOTALINVOKES"
        getCounts
done
log "ALL $TOTALINVOKES INVOKEs execution time $(($(date +%s)-START_TIME_INVOKE)) secs" $LOG_TIMING

#Queries
START_TIME_QUERY=$(date +%s)
loop_through_all "$QUERYACTION"
getCounts
while test $TOTALINVOKES -ne $(( $QMATCHCOUNT + $QERRORCOUNT ))
do
        verifyResult $QERRORCOUNT "EXIT MAIN THREAD DUE TO QUERY ERROR"
        logsleep 2 "more queries ... QMATCHCOUNT = $QMATCHCOUNT / $TOTALINVOKES"
        getCounts
done
log "ALL $TOTALINVOKES QUERYs execution time $(($(date +%s)-START_TIME_QUERY)) secs" $LOG_TIMING

printSummary "Full test execution COMPLETED"

exit 0
