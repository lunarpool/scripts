#!/bin/bash

# Script is brought to you by ATADA_Stakepool, Telegram @atada_stakepool

#load variables from common.sh
#       socket          Path to the node.socket (also exports socket to CARDANO_NODE_SOCKET_PATH)
#       genesisfile     Path to the genesis.json
#       magicparam      TestnetMagic parameter
#       cardanocli      Path to the cardano-cli executable
#       cardanonode     Path to the cardano-node executable
. "$(dirname "$0")"/00_common.sh

case $# in
  2 ) delegName="$1";
      regPayName="$2";;
  * ) cat >&2 <<EOF

Usage:  $(basename $0) <DelegatorName> <PaymentAddrForRegistration>

Ex.: $(basename $0) owner owner.payment   (reg. owner.staking.addr with owner.deleg.cert, owner.payment.addr is paying the fees)
Ex.: $(basename $0) delegator1 myfunds    (reg. delegator1.staking.addr with delegator1.deleg.cert, myfunds.addr is payming the fees)

EOF
  exit 1;; esac

if [ ! -f "${delegName}.deleg.cert" ]; then echo -e "\n\e[35mERROR - \"${delegName}.deleg.cert\" does not exist! Please create it first with script 05b.\e[0m"; exit 1; fi
if [ ! -f "${delegName}.staking.skey" ]; then echo -e "\n\e[35mERROR - \"${delegName}.staking.skey\" does not exist! Please create it first with script 03a & 03b.\e[0m"; exit 1; fi
if [ ! -f "${regPayName}.addr" ]; then echo -e "\n\e[35mERROR - \"${regPayName}.addr\" does not exist! Please create it first with script 03a.\e[0m"; exit 1; fi
if [ ! -f "${regPayName}.skey" ]; then echo -e "\n\e[35mERROR - \"${regPayName}.skey\" does not exist! Please create it first with script 03a.\e[0m"; exit 1; fi

echo
echo -e "\e[0mRegister Delegation Certificate\e[32m ${delegName}.deleg.cert\e[0m with funds from Address\e[32m ${regPayName}.addr\e[0m:"
echo

#get values to register the staking address on the blockchain
#get live values
currentTip=$(get_currentTip)
ttl=$(get_currentTTL)
currentEPOCH=$(get_currentEpoch)

echo -e "Current Slot-Height:\e[32m ${currentTip}\e[0m (setting TTL to ${ttl})"

rxcnt="1"               #transmit to one destination addr. all utxos will be sent back to the fromAddr

sendFromAddr=$(cat ${regPayName}.addr); check_address "${sendFromAddr}";
sendToAddr=$(cat ${regPayName}.addr); check_address "${sendToAddr}";

echo
echo -e "Pay fees from Address\e[32m ${regPayName}.addr\e[0m: ${sendFromAddr}"
echo


#Get UTX0 Data for the sendFromAddr
utx0=$(${cardanocli} shelley query utxo --address ${sendFromAddr} --cardano-mode ${magicparam}); checkError "$?";
utx0linecnt=$(echo "${utx0}" | wc -l)
txcnt=$((${utx0linecnt}-2))

if [[ ${txcnt} -lt 1 ]]; then echo -e "\e[35mNo funds on the payment Addr!\e[0m"; exit; else echo "${txcnt} UTXOs found on the payment Addr!"; fi

echo

#Calculating the total amount of lovelaces in all utxos on this address
totalLovelaces=0
txInString=""

while IFS= read -r utx0entry
do
fromHASH=$(echo ${utx0entry} | awk '{print $1}')
fromHASH=${fromHASH//\"/}
fromINDEX=$(echo ${utx0entry} | awk '{print $2}')
sourceLovelaces=$(echo ${utx0entry} | awk '{print $3}')
echo -e "HASH: ${fromHASH}\t INDEX: ${fromINDEX}\t LOVELACES: ${sourceLovelaces}"

totalLovelaces=$((${totalLovelaces}+${sourceLovelaces}))
txInString=$(echo -e "${txInString} --tx-in ${fromHASH}#${fromINDEX}")

done < <(printf "${utx0}\n" | tail -n ${txcnt})

echo -e "Total lovelaces in UTX0:\e[32m  ${totalLovelaces} lovelaces \e[90m"
echo

#Getting protocol parameters from the blockchain, calculating fees
${cardanocli} shelley query protocol-parameters --cardano-mode ${magicparam} > protocol-parameters.json
checkError "$?"

#Generate Dummy-TxBody file for fee calculation
        txBodyFile="${tempDir}/dummy.txbody"
        rm ${txBodyFile} 2> /dev/null
        ${cardanocli} shelley transaction build-raw ${txInString} --tx-out ${sendToAddr}+0 --ttl ${ttl} --fee 0 --certificate ${delegName}.deleg.cert --out-file ${txBodyFile}
        checkError "$?"

fee=$(${cardanocli} shelley transaction calculate-min-fee --tx-body-file ${txBodyFile} --protocol-params-file protocol-parameters.json --tx-in-count ${txcnt} --tx-out-count ${rxcnt} ${magicparam} --witness-count 2 --byron-witness-count 0 | awk '{ print $1 }')
checkError "$?"

echo -e "\e[0mMinimum transfer Fee for ${txcnt}x TxIn & ${rxcnt}x TxOut & 1x Certificate: \e[32m ${fee} lovelaces \e[90m"
minRegistrationFund=$(( ${fee} ))

echo
echo -e "\e[0mMinimum funds required for registration (Sum of fees): \e[32m ${minRegistrationFund} lovelaces \e[90m"
echo

#calculate new balance for destination address
lovelacesToSend=$(( ${totalLovelaces}-${minRegistrationFund} ))

#Checking about minimum funds in the UTX0
if [[ ${lovelacesToSend} -lt 0 ]]; then echo -e "\e[35mNot enough funds on the payment Addr!\e[0m"; exit; fi

echo -e "\e[0mLovelaces that will be returned to payment Address (UTXO-Sum minus fees): \e[32m ${lovelacesToSend} lovelaces \e[90m"
echo

txBodyFile="${tempDir}/$(basename ${regPayName}).txbody"
txFile="${tempDir}/$(basename ${regPayName}).tx"

echo
echo -e "\e[0mBuilding the unsigned transaction body with Delegation Certificate\e[32m ${delegName}.deleg.cert\e[0m certificates: \e[32m ${txBodyFile} \e[90m"
echo

#Building unsigned transaction body
rm ${txBodyFile} 2> /dev/null
${cardanocli} shelley transaction build-raw ${txInString} --tx-out ${sendToAddr}+${lovelacesToSend} --ttl ${ttl} --fee ${fee} --certificate ${delegName}.deleg.cert --out-file ${txBodyFile}
checkError "$?"

cat ${txBodyFile}
echo
echo
echo -e "\e[0mSign the unsigned transaction body with the \e[32m${regPayName}.skey\e[0m & \e[32m${delegName}.staking.skey\e[0m: \e[32m ${txFile} \e[90m"
echo

#Sign the unsigned transaction body with the SecureKey
rm ${txFile} 2> /dev/null
${cardanocli} shelley transaction sign --tx-body-file ${txBodyFile} --signing-key-file ${regPayName}.skey --signing-key-file ${delegName}.staking.skey ${magicparam} --out-file ${txFile}
checkError "$?"

cat ${txFile}
echo
echo

if ask "\e[33mDoes this look good for you ?" N; then
        echo
        echo -ne "\e[0mSubmitting the transaction via the node..."
        ${cardanocli} shelley transaction submit --tx-file ${txFile} --cardano-mode ${magicparam}
	checkError "$?"
        echo -e "\e[32mDONE\n"
fi

echo -e "\e[0m\n"
