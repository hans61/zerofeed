#!/bin/bash

# Zero feed script to make sure the solar modules are reducing their output
# to (ideally) not push any energy into the public network.

# Inspired by https://github.com/tbnobody/OpenDTU/blob/master/docs/Web-API.md

# Needs OpenDTU and the Tasmota smart meter IoT devices in your WLAN and is
# intended to be executed on an OpenWrt router (install curl & jq packages).
# USE AT YOUR OWN RISK! Especially I don't know if the inverter is fit for
# this purpose as all this functionality was reverse engineered by the
# fabulous OpenDTU developers. I simply rely on their amazing work here.

# Author: Oliver Hartkopp
# License: MIT

# Exit if 'bash' is not installed
test -x /bin/bash || exit 0

# Exit if 'curl' is not installed
test -x /usr/bin/curl || exit 0

# Exit if 'jq' is not installed
test -x /usr/bin/jq || exit 0

# Current Smart Meter Power (signed value)
# -> should become a small positive value ;-)
SMPWR=0

# Current Solar Power (unsigned value)
SOLPWR=0

# Absolute Solar Limit (unsigned value)
# -> SMPWR + SOLPWR + ABSLIMITOFFSET
SOLABSLIMIT=0

# reduce safety margin from inverter by increasing this value
ABSLIMITOFFSET=0

# SMPWR threshold to trigger the SOLLASTLIMIT increase
SMPWRTHRESMAX=50
SMPWRTHRESMIN=20

# SmartMeter IP (Tasmota) (update for your local network setup)
SMIP=192.168.1.11

# DTU IP (OpenDTU) (update for your local network setup)
DTUIP=192.168.1.10

# DTU default admin user access (from OpenDTU installation)
DTUUSER="admin:openDTU42"

# DTU serial numbers (insert your inverter SNs here)
# N.B. the size of this array has to be transferred to the arrays below
# namely the arrays: DTULIM DTUMAXP DTUMINP DTULASTSOLPWR
#DTUSN=(116190745467)
DTUSN=(114191225784 112183846592 112183845286 112183845625 112183845820)

# manual limits to override the detected inverter limits (in Watt) (0 = disabled)
#DTULIM=(600 800 1000)
DTULIM=(800 400 400 400 400)

# initialize arrays for inverter specific values
DTUMAXP=(0 0 0 0 0)
DTUMINP=(0 0 0 0 0)

# initialize arrays for inverter specific values
DTULASTSOLPWR=(0 0 0)

MAXDTUIDX=$((${#DTUSN[@]} - 1))
CURRDTU=0

# the minimum inverter max power (sanity check)
MINDTUPWR=100

# DTU limiter (should be this at 100% after > 0W start)
DTULIMREL=0

# limit type absolute (non persistent)
LTABSNP=0
# limit type relative (non persistent)
LTRELNP=1

getSOLPWR()
{
    # get power from the single selected inverter
    #SOLPWR=`curl -s http://$DTUIP/api/livedata/status | jq '.inverters[] | select(.serial == "'${DTUSN[$CURRDTU]}'").AC."0".Power.v'`

    # BREAKING CHANGE in openDTU API v24.2.12, 2024-01-30 see:
    # https://github.com/tbnobody/OpenDTU/releases/tag/v24.2.12
    read -d "\n" SOLALLPWR YIELDDAY SOLPWR <<< `curl -s http://$DTUIP/api/livedata/status | jq '.total.Power.v, .total.YieldDay.v, (.inverters[] | select(.serial == "'${DTUSN[$CURRDTU]}'").AC."0".Power.v)'`
    # read -d "\n" SOLALLPWR YIELDDAY SOLPWR <<< `curl -s http://$DTUIP/api/livedata/status?inv=${DTUSN[$CURRDTU]} | jq '.total.Power.v, .total.YieldDay.v, .inverters[].AC."0".Power.v'` # -> does not work with multiple inverters, the result of SOLPWR is an array
	
    if [ -n "$SOLPWR" ]
    then
	# remove fraction to make it an integer
	SOLPWR=${SOLPWR%.*}
	DTULASTSOLPWR[$CURRDTU]=$SOLPWR
    fi
    if [ -n "$SOLALLPWR" ]
    then
	# remove fraction to make it an integer
	SOLALLPWR=${SOLALLPWR%.*}
    fi
}

waitDTUpowerUp()
{
    NOPOWER=1
    while [ "$NOPOWER" -eq "1" ]
    do
	NOPOWER=0
	CURRDTU=0
	while [ "$CURRDTU" -le "$MAXDTUIDX" ]
	do
	    getSOLPWR
	    if [ -z "$SOLPWR" ] || [ "$SOLPWR" -lt "5" ]
	    then
		echo `date +#P\ %d.%m.%y\ %T`" NOPOWER for DTU "$CURRDTU" ("$SOLPWR"W)"
		NOPOWER=1
		break
	    fi
	    ((CURRDTU+=1))
	done
	if [ -z "$SOLPWR" ]
	then
	    NOPOWER=1
	    break
	fi
	if [ "$NOPOWER" -eq "1" ]
	then
	    sleep 60
	fi
    done
}

getDTUMAXPWR()
{
    DTUMAXPWR=`curl -s http://$DTUIP/api/limit/status | jq '."'${DTUSN[$CURRDTU]}'".max_power'`
    if [ -n "$DTUMAXPWR" ]
    then
	# remove fraction to make it an integer
	DTUMAXP[$CURRDTU]=${DTUMAXPWR%.*}
	echo "DTUMAXP["$CURRDTU"] = "${DTUMAXP[$CURRDTU]}
	# 2% is the minimum control boundary - so take 3% to be sure
	DTUMINP[$CURRDTU]=$(($DTUMAXPWR / 33))
	echo "DTUMINP["$CURRDTU"] = "${DTUMINP[$CURRDTU]}
    fi
}

getDTULIMREL()
{
    DTULIMREL=`curl -s http://$DTUIP/api/limit/status | jq '."'${DTUSN[$CURRDTU]}'".limit_relative'`
    if [ -n "$DTULIMREL" ]
    then
	# remove fraction to make it an integer
	DTULIMREL=${DTULIMREL%.*}
    fi
}

# get current power via 'status 8' from Tasmota (for LK13BE smart meter)
getSMPWR()
{
    #SMPWR=`curl -s http://$SMIP/cm?cmnd=status%208 | jq '.StatusSNS.LK13BE.Power_curr'`
    #read -d "\n" SMPWR SMPWRIN SMPWROUT <<< `curl -s http://$SMIP/cm?cmnd=status%208 | jq '.StatusSNS.LK13BE | .Power_curr,.Power_total_in,.Power_total_out'`
	read -d "\n" SMPWR SMPWRIN SMPWROUT <<< `curl -s http://$SMIP/cm?cmnd=status%208 | jq '.StatusSNS.DWS7410 | .power,.energy,.en_out'` # SM DWS7420.2.G2
    if [ -n "$SMPWR" ]
    then
	# remove fraction to make it an integer
	SMPWR=${SMPWR%.*}
    fi
}

getLimitSetStatus()
{
    SETSTATUS="\"Pending\""

    while [ "$SETSTATUS" = "\"Pending\"" ]
    do
	sleep 1
	SETSTATUS=`curl -s http://$DTUIP/api/limit/status | jq '."'${DTUSN[$CURRDTU]}'".limit_set_status'`
	# SETSTATUS can be "Ok" or "Pending" or "Failure"
	echo "SETSTATUS="$SETSTATUS
    done
}

printState()
{
    echo -n `date +%d.%m.%y,%T`","$YIELDDAY","$SOLALLPWR","$SOLPWR","$SMPWR","$SMPWRIN","$SMPWROUT","$SOLABSLIMIT","$SOLLASTLIMIT","$ABSLIMITOFFSET","$SMPWRTHRESMIN","$SMPWRTHRESMAX","$MAXDTUIDX","$CURRDTU
    #cho -n `date +%d.%m.%y,%T`","$YIELDDAY","$SOLALLPWR","$SOLPWR","$SMPWR","$SMPWRIN","$SMPWROUT","$SOLABSLIMIT","$SOLLASTLIMIT","$ABSLIMITOFFSET","$SMPWRTHRESMIN","$SMPWRTHRESMAX","$MAXDTUIDX","$CURRDTU > /var/run/zerofeed.state

    PRINTDTU=0
    while [ "$PRINTDTU" -le "$MAXDTUIDX" ]
    do
	echo -n ","$PRINTDTU,${DTULASTSOLPWR[$PRINTDTU]}
	#cho -n ","$PRINTDTU,${DTULASTSOLPWR[$PRINTDTU]} >> /var/run/zerofeed.state
	((PRINTDTU+=1))
    done

    echo
    #cho >> /var/run/zerofeed.state
}

# run initialization and solar power control forever
while [ true ]
do
    echo `date +#I\ %d.%m.%y\ %T`
    CURRDTU=0
    getSOLPWR
    getSMPWR
    getDTULIMREL
    echo "initSOLPWR="$SOLPWR
    echo "initSMPWR="$SMPWR
    echo "initDTULIMREL="$DTULIMREL

    # wait until curl succeeds
    while [ -z "$SOLPWR" ] || [ -z "$SMPWR" ]
    do
	echo `date +#W\ %d.%m.%y\ %T`
	echo "Wait for devices"
	sleep 10
	getSOLPWR
	getSMPWR

    done

    waitDTUpowerUp
    if [ "$NOPOWER" -eq "1" ]
    then
	echo restart waitDTUpowerUp
	continue
    fi
    echo waitDTUpowerUp done

    # get maximum power of inverters and fill DTUMAXP[] & DTUMINP[]
    RESTART=0
    CURRDTU=0
    while [ "$CURRDTU" -le "$MAXDTUIDX" ]
    do
	getDTULIMREL
	if [ -z "$DTULIMREL" ]
	then
	    # no data -> restart process
	    RESTART=1
	    break
	fi
	echo "DTULIMREL["$CURRDTU"] = "$DTULIMREL"%"

	getDTUMAXPWR
	if [ -z "$DTUMAXPWR" ] || [ "${DTUMAXP[$CURRDTU]}" -lt "$MINDTUPWR" ]
	then
	    # no data / weird inverter -> restart process
	    RESTART=1
	    break
	fi

	# check for manual limit override
	if [ "${DTULIM[$CURRDTU]}" -ge "${DTUMINP[$CURRDTU]}" ] && [ "${DTULIM[$CURRDTU]}" -le "${DTUMAXP[$CURRDTU]}" ]
	then
	    DTUMAXP[$CURRDTU]=${DTULIM[$CURRDTU]}
	    echo setting manual limit DTUMAXP[$CURRDTU] to ${DTUMAXP[$CURRDTU]} W
	fi

	((CURRDTU+=1))
    done

    if [ "$RESTART" -eq "1" ]
    then
	echo restart at getDTUMAXPWR
	continue
    fi

    # set OK value if we do not need to set the relative limit
    SETSTATUS="\"Ok\""

    # set limiters to start from the bottom
    echo
    echo `date +#L\ %d.%m.%y\ %T`
    echo init non permanent limits on all inverters
    RESTART=0
    CURRDTU=0
    while [ "$CURRDTU" -le "$MAXDTUIDX" ]
    do
	echo setting non permanent limit for inverter $CURRDTU to ${DTUMINP[$CURRDTU]} W
	SETLIM=`curl -u "$DTUUSER" http://$DTUIP/api/limit/config -d 'data={"serial":"'${DTUSN[$CURRDTU]}'", "limit_type":'$LTABSNP', "limit_value":'${DTUMINP[$CURRDTU]}'}' 2>/dev/null | jq '.type'`
	echo "SETLIM="$SETLIM
	getLimitSetStatus

	# SETSTATUS can be "Ok" or "Failure" here
	if [ "$SETSTATUS" != "\"Ok\"" ]
	then
	    echo setting the absolute limit of inverter failed
	    RESTART=1
	    break
	fi
	((CURRDTU+=1))
    done

    if [ "$RESTART" -eq "1" ]
    then
	echo restart at set init limits
	continue
    fi

    CURRDTU=0
    getSOLPWR
    getSMPWR
    # last check before starting the control loop
    if [ -z "$SMPWR" ] || [ -z "$SOLPWR" ]
    then
	echo restart before control loop
	continue
    fi

    # start from the top
    SOLLASTLIMIT=$((${DTUMAXP[$CURRDTU]} + 1))

    # main control loop
    while [ -n "$SMPWR" ] && [ -n "$SOLPWR" ]
    do
	echo
	echo `date +#C\ %d.%m.%y\ %T`
	echo "SOLALLPWR="$SOLALLPWR
	echo "SOLPWR="$SOLPWR
	echo "CURRDTU="$CURRDTU
	echo "SMPWR="$SMPWR
	echo "SOLLASTLIMIT="$SOLLASTLIMIT
	echo "SOLABSLIMIT="$SOLABSLIMIT

	if [ "$SMPWR" -lt "$SMPWRTHRESMIN" ]
	then
	    # calculate inverter limit to stop feeding into public network
	    SOLABSLIMIT=$(($SMPWR + $SOLPWR - $SMPWRTHRESMIN + $ABSLIMITOFFSET))
	    echo "set SOLABSLIMIT="$SOLABSLIMIT
	elif [ "$SMPWR" -gt "$SMPWRTHRESMAX" ]
	then
	    # the system power consumption is higher than our defined threshold
	    # => we could safely increase the current SOLLASTLIMIT by SMPWR
	    #    until DTUMAXPWR is reached (see following if-statement).
	    #    SOLABSLIMIT=$(($SMPWR + $SOLLASTLIMIT - $SMPWRTHRESMIN))
	    #
	    # As there was a weird oscillation observed with real SMPWR values
	    # we make smaller steps with SMPWRTHRESMAX towards DTUMAXPWR instead.
	    # When SMPWR is 'really big' we jump half of the SMPWR value.
	    if [ "$SMPWR" -gt $((2 * $SMPWRTHRESMAX)) ]
	    then
		PWRINCR=$(($SMPWR / 2))
	    else
		PWRINCR=$SMPWRTHRESMAX
	    fi

	    SOLABSLIMIT=$(($PWRINCR + $SOLLASTLIMIT - $SMPWRTHRESMIN))
	    echo "update SOLABSLIMIT="$SOLABSLIMIT
	fi

	# when hopping between inverters start with current SMPWR value
	if [ "$SOLLASTLIMIT" -eq "$((${DTUMAXP[$CURRDTU]} + 1))" ]
	then
	    SOLABSLIMIT=$SMPWR
	    echo "hop detected - set SOLABSLIMIT to SMPWR ("$SOLABSLIMIT")"
	fi

	# do not set limits beyond the inverter capabilities
	if [ "$SOLABSLIMIT" -gt "${DTUMAXP[$CURRDTU]}" ]
	then
	    echo Calculated limit $SOLABSLIMIT cropped to ${DTUMAXP[$CURRDTU]}
	    SOLABSLIMIT=${DTUMAXP[$CURRDTU]}
	fi

	# do not set limits beyond the inverter capabilities
	if [ "$SOLABSLIMIT" -lt "${DTUMINP[$CURRDTU]}" ]
	then
	    echo Calculated limit $SOLABSLIMIT cropped to ${DTUMINP[$CURRDTU]}
	    SOLABSLIMIT=${DTUMINP[$CURRDTU]}
	fi

	# when we moved far away from SOLPOWER -> hop to the maximum
	if [ "$(($SOLABSLIMIT - $SOLPWR))" -gt "200" ] && [ "$(($SOLABSLIMIT - $SOLLASTLIMIT))" -lt "150" ]
	then
	    echo Fast hop of inverter $CURRDTU to ${DTUMAXP[$CURRDTU]}
	    SOLABSLIMIT=${DTUMAXP[$CURRDTU]}
	fi

	# only set the limit when the value was changed
	if [ "$SOLABSLIMIT" -ne "$SOLLASTLIMIT" ]
	then
	    SETLIM=`curl -u "$DTUUSER" http://$DTUIP/api/limit/config -d 'data={"serial":"'${DTUSN[$CURRDTU]}'", "limit_type":'$LTABSNP', "limit_value":'$SOLABSLIMIT'}' 2>/dev/null | jq '.type'`
	    echo "SETLIM="$SETLIM" on inverter "$CURRDTU
	    getLimitSetStatus
	fi

	# SETSTATUS can be "Ok" or "Failure" here
	if [ "$SETSTATUS" != "\"Ok\"" ]
	then
	    echo setting the abs limit failed
	    # setting the limit failed -> restart process
	    break
	fi

	SOLLASTLIMIT=$SOLABSLIMIT

	# check for inverter change
	if [ "$SOLABSLIMIT" -eq "${DTUMINP[$CURRDTU]}" ] && [ "$CURRDTU" -gt "0" ]
	then
	    echo -n "step down from inverter "$CURRDTU
	    ((CURRDTU-=1))
	    echo " to inverter "$CURRDTU
	    SOLLASTLIMIT=${DTUMAXP[$CURRDTU]}
	    # set a default value when SMPWRTHRESMIN < SOLPWR < SMPWRTHRESMAX
	    SOLABSLIMIT=${DTUMINP[$CURRDTU]}
	else if [ "$SOLABSLIMIT" -eq "${DTUMAXP[$CURRDTU]}" ] && [ "$CURRDTU" -lt "$MAXDTUIDX" ]
	     then
		 echo -n "step up from inverter "$CURRDTU
		 ((CURRDTU+=1))
		 echo " to inverter "$CURRDTU
		 SOLLASTLIMIT=$((${DTUMAXP[$CURRDTU]} + 1))
		 # set a default value when SMPWRTHRESMIN < SOLPWR < SMPWRTHRESMAX
		 SOLABSLIMIT=${DTUMINP[$CURRDTU]}
	     fi
	fi

	# generate CSV capable status output
	printState

	getSMPWR
	SOLTIMEOUT=4
	while [ -n "$SMPWR" ] && [[ "$SMPWR" -gt "$SMPWRTHRESMIN" ]] && [ "$SOLTIMEOUT" -gt "0" ]
	do
	    sleep 1
	    getSMPWR
	    ((SOLTIMEOUT-=1))
	    printState
	done

	getSOLPWR

	# restart whole process
	if [ -z "$SOLPWR" ] || [ "$SOLPWR" -eq "0" ] || [ -z "$SMPWR" ]
	then
	    unset SOLPWR
	    unset SMPWR
	    break
	fi

    done

    echo restart
done
