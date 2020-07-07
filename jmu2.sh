#!/bash/sh 

function run {

	user=${1:-$USER}
	if [ -z "$user" ]; then
		user="user$RANDOM"
	fi

	testId=${2:-$TESTID}
	if [ -z "$testId" ]; then
		testId="Test $(date)"
	fi

	echo "***************************************************"
	hostId=$(hostname)
	echo $hostId
	os=$(cat /etc/*-release)
	echo $os
	nodeType=""
	meta="/etc/jelastic/metainf.conf"
	if [ -f $meta ]; then
		nodeType=$(cat $meta | grep TYPE)
		echo $nodeType
	fi 
	mem=$(free -m | grep -v +)
	echo $mem

	osMemTotal=$(echo $mem | cut -d' ' -f8)
	osMemUsed=$(echo $mem | cut -d' ' -f9)
	osMemFree=$(echo $mem | cut -d' ' -f10)
	osMemShared=$(echo $mem | cut -d' ' -f11)
	osMemBuffCache=$(echo $mem | cut -d' ' -f12)
	osMemAvail=$(echo $mem | cut -d' ' -f13)
	swapTotal=$(echo $mem | cut -d' ' -f15)
	swapUsed=$(echo $mem | cut -d' ' -f16)
	swapFree=$(echo $mem | cut -d' ' -f17)
	dockerVersion=$(docker -v)
    if [ $(which kubeadm) ]; then
		$dockerVersion=$(echo -e "$dockerVersion\n$(kubeadm version | tr -d '&')")
    fi
    echo $dockerVersion
	port=10239
	curl -sLo /tmp/jattach https://github.com/apangin/jattach/releases/download/v1.5/jattach
	chmod +x /tmp/jattach
	jattach="/tmp/jattach"
	curl -sLo /tmp/app.jar https://github.com/siruslan/java-memory-usage/raw/master/MemoryUsageCollector.jar
	jar=/tmp/app.jar

	for pid in $(pgrep -l java | awk '{print $1}'); do
		echo "-------------- $pid --------------"
		echo "$jattach $pid jcmd VM.version"
		javaVersion=$($jattach $pid jcmd VM.version | grep -v "Connected to remote JVM" | grep -v "Response code = 0")
		result=$?
		if [ $result -ne 0 ]; then
			javaVersion="Java on Host: $(java -version 2>&1)"
			result=$?
		fi

		if [ $(which docker) ]; then
			echo "Collecting info about docker container limits..."
			ctid=$(getCtInfo $pid id)
			echo "ctid=$ctid"
			st=$(docker stats $ctid --no-stream --format "{{.MemUsage}}")
			dockerUsed=$(echo $st | cut -d'/' -f1 | tr -s " " | xargs)
			dockerLimit=$(echo $st | cut -d'/' -f2 | tr -s " " | xargs)
			if [ $result -ne 0 ]; then
				javaVersion=$(docker exec $ctid java -version 2>&1) 
			fi
		fi

		echo $javaVersion

		if [[ "$javaVersion" == *"JDK 7."* || "$javaVersion" == *"1.7."* ]]; then
			echo "ERROR: Java 7 is not supported"
		else
			echo "$jattach $pid jcmd VM.flags"
			jvmFlags=$($jattach $pid jcmd VM.flags | grep -v "Connected to remote JVM" | grep -v "Response code = 0")
			echo $jvmFlags

			s=":InitialHeapSize="
			initHeap=$(toMB $(echo ${jvmFlags#*$s} | cut -d' ' -f1))
			s=":MaxHeapSize="
			maxHeap=$(toMB $(echo ${jvmFlags#*$s} | cut -d' ' -f1))
			s=":MaxNewSize="
			maxNew=$(toMB $(echo ${jvmFlags#*$s} | cut -d' ' -f1))
			s=":MinHeapDeltaBytes="
			minHeapDelta=$(toMB $(echo ${jvmFlags#*$s} | cut -d' ' -f1))
			s=":NewSize="
			newSize=$(toMB $(echo ${jvmFlags#*$s} | cut -d' ' -f1))
			s=":OldSize="
			oldSize=$(toMB $(echo ${jvmFlags#*$s} | cut -d' ' -f1))


			currentPort=$($jattach $pid jcmd ManagementAgent.status | grep jmxremote.port | cut -d'=' -f2 | tr -s " " | xargs)
			if [ -z "$currentPort" ]; then
				s="jmxremote.port="
				proc=$(ps ax | grep $pid | grep $s)
				currentPort=$(echo ${proc#*$s} | cut -d'=' -f1)
			fi			
			if [ -z "$currentPort" ]; then
				start="ManagementAgent.start jmxremote.port=$port jmxremote.rmi.port=$port jmxremote.ssl=false jmxremote.authenticate=false"
				echo "$jattach $pid jcmd \"$start\""
				resp=$($jattach $pid jcmd "$start" 2>&1)
				result=$?
				echo $resp
				p=$port
			else 
				result=0
				echo "Connecting to running JMX at port $currentPort"
				p=$currentPort
			fi
			

			if [ $result -eq 0 ]; then
				echo "java -jar $jar -p=$p 2>&1"
				resp=$(java -jar $jar -p=$p 2>&1)
				result=$?
				echo $resp

				if [ $(which docker) ]; then
					if [[ "$resp" == *"Failed to retrieve RMIServer stub"* ]]; then
						ip=$(getCtInfo $pid)	
						echo "java -jar $jar -h=$ip -p=$p"
						resp=$(java -jar $jar -h=$ip -p=$p)
						result=$?
						echo $resp
					fi
					#If previous attempts failed then execute java -jar app.jar inside docker cotainer 
					if [ $result -ne 0 ]; then
						docker cp $jar $ctid:$jar
						resp=$(docker exec $ctid java -jar $jar -p=$p) 
						result=$?
						docker exec -u 0 $ctid rm -rf $jar 
						echo $resp
					fi
				fi

				options=$(echo $resp | cut -d'|' -f1)
				if [ $result -eq 0 ]; then
					xms=$(echo $resp | cut -d'|' -f2)
					heapUsed=$(echo $resp | cut -d'|' -f3)
					heapCommitted=$(echo $resp | cut -d'|' -f4)
					xmx=$(echo $resp | cut -d'|' -f5)
					nonHeapInit=$(echo $resp | cut -d'|' -f6)
					nonHeapUsed=$(echo $resp | cut -d'|' -f7)
					nonHeapCommitted=$(echo $resp | cut -d'|' -f8)
					nonHeapMax=$(echo $resp | cut -d'|' -f9)
					gcType=$(echo $resp | cut -d'|' -f10)
					nativeMemory=$(echo $resp | cut -d'|' -f11)
				fi
				if [ -z "$currentPort" ]; then
					echo "$jattach $pid jcmd ManagementAgent.stop"
					$jattach $pid jcmd ManagementAgent.stop
				fi
				echo "Done"
			else
				if [ $(which docker) ]; then
					if [[ "$resp" == *"Failed to retrieve RMIServer stub"* ]]; then
						ip=$(getCtInfo $pid)	
						echo "java -jar $jar -h=$ip"
						resp=$(java -jar $jar -h=$ip)
						result=$?
						echo $resp
					fi
					#If previous attempts failed then execute java -jar app.jar inside docker cotainer 
					if [ $result -ne 0 ]; then
						ctid=$(getCtInfo $pid id)
						docker cp $jar $ctid:$jar
						resp=$(docker exec $ctid java -jar $jar) 
						result=$?
						docker exec -u 0 $ctid rm -rf $jar 
						echo $resp
					fi
				fi
				options="$resp"
				echo "ERROR: can't enable JMX for pid=$pid"
			fi
		fi

		curl -fsSL -d "user=$user&testId=$testId&hostId=$hostId&os=$os&nodeType=$nodeType&pid=$pid&osMemTotal=$osMemTotal&osMemUsed=$osMemUsed&osMemFree=$osMemFree&osMemShared=$osMemShared&osMemBuffCache=$osMemBuffCache&osMemAvail=$osMemAvail&swapTotal=$swapTotal&swapUsed=$swapUsed&swapFree=$swapFree&javaVersion=$javaVersion&options=$options&gcType=$gcType&xmx=$xmx&heapCommitted=$heapCommitted&heapUsed=$heapUsed&xms=$xms&nonHeapMax=$nonHeapMax&nonHeapCommitted=$nonHeapCommitted&nonHeapUsed=$nonHeapUsed&nonHeapInit=$nonHeapInit&nativeMemory=$nativeMemory&jvmFlags=$jvmFlags&initHeap=$initHeap&maxHeap=$maxHeap&minHeapDelta=$minHeapDelta&maxNew=$maxNew&newSize=$newSize&oldSize=$oldSize&dockerVersion=$dockerVersion&dockerUsed=$dockerUsed&dockerLimit=$dockerLimit" -X POST "https://cs.demo.jelastic.com/1.0/development/scripting/rest/eval?script=stats&appid=cc492725f550fcd637ab8a7c1f9810c9"
		echo ""
	done
	rm -rf $jar $jattach
}

function getCtInfo {
	local pid="$1"

	if [[ -z "$pid" ]]; then
		echo "Missing host PID argument."
		exit 1
	fi

	if [ "$pid" -eq "1" ]; then
		echo "Unable to resolve host PID to a container name."
		exit 2
	fi

  #ps returns values potentially padded with spaces, so we pass them as they are without quoting.
  local parentPid="$(ps -o ppid= -p $pid)"
  local ct="$(ps -o args= -f -p $parentPid | grep containerd-shim)"
  m="moby/"
  if [[ -n "$ct" ]]; then
  	local ctid=$(echo ${ct#*$m} | cut -d' ' -f1)
  	if [ "$2" == "id" ]; then
  		echo $ctid
  	else
  		docker inspect $ctid | grep IPAddress | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"
  	fi
  else
  	getCtInfo "$parentPid" $2
  fi
}

function toMB {
	local mb=1048576
	local value=$1

	if echo "$value" | grep -qE '^[0-9]+$' ; then
		echo $(($value/$mb))
	else
		echo ""
	fi	
}

run $1 $2