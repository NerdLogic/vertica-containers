#!/bin/bash

# this is a full example of configuring and running a scheduler.  It uses
# docker-compose to create a kafka and vertica service, then it

# first chose a unique project name for docker-compose
cd "$(dirname ${BASH_SOURCE[0]})" || exit $?
source ./.env || exit $?
NETWORK=${COMPOSE_PROJECT_NAME}_example
: ${VERTICA_VERSION:=v12.0.3}
export VERTICA_K8S_VERSION=${VERTICA_VERSION#v}-0-minimal


########################
# Debugging and Colors #
########################

# TO only run certain steps, export steps variable like so:
# steps="start setup" ./example.sh
: ${steps=ssl start setup run write stop clean}

# see if sed can make the log output green to make it easier to diferentiate
esc=$'\e'
green="sed -u -e s/\(.*\)/$esc[32m\1$esc[39m/" # for normal output
red="sed -u -e s/\(.*\)/$esc[31m\1$esc[39m/"   # for errors
blue="sed -u -e s/\(.*\)/$esc[34m\1$esc[39m/"  # for log output
if ! echo | $green >/dev/null 2>&1; then
  green=cat
  red=cat
  blue=cat
fi

DOCKER_OPTS+=(
  --rm \
  -v $PWD/example.conf:/etc/vkconfig.conf \
  -v $PWD/vkafka-log-config-debug.xml:/opt/vertica/packages/kafka/config/vkafka-log-config.xml \
  -v $PWD/log:/opt/vertica/log \
  --network $NETWORK \
  --user $(id -u):$(id -g) \
  --name kafka_scheduler \
  )

##########################
# CREATE SSL CERTS       #
##########################
#
# to turn off SSL, set NO_SSL to something like this:
# NO_SSL=1 ./example.sh
#
if [[ -z $NO_SSL ]] ; then
  PASSWORD=example
  if [[ $steps =~ ssl ]]; then
    rm -rf security
    mkdir -p security

    # create CA
    OPENSSL="docker run --user $(id -u):$(id -g) -v $PWD:$PWD -w $PWD alpine/openssl"
    $OPENSSL req -config openssl.cnf -new -x509 -keyout security/example.ca-key -out security/example.ca-cert -days 365 -subj "/C=US/ST=Massachusetts/L=Cambridge/CN=ca" -passout pass:$PASSWORD 2>&1 | $blue
    docker run --user $(id -u):$(id -g) -v $PWD:$PWD -w $PWD alpine/openssl req -config openssl.cnf -new -x509 -keyout security/example.ca-key -out security/example.ca-cert -days 365 -subj "/C=US/ST=Massachusetts/L=Cambridge/CN=ca" -passout pass:$PASSWORD 2>&1 | $blue

    # create truststore containing CA
    KEYTOOL="docker run --user $(id -u):$(id -g) -v $PWD:$PWD -w $PWD vertica/kafka-scheduler:$VERTICA_VERSION keytool"
    $KEYTOOL -keystore security/example.truststore.jks -deststoretype pkcs12 -alias caroot -import -file security/example.ca-cert -storepass $PASSWORD -keypass $PASSWORD -noprompt 2>&1 | $green

    # kafka's keystore
    $KEYTOOL -keystore security/exampleK.keystore.jks -deststoretype pkcs12 -alias exampleK -validity 365 -keyalg RSA -genkey -dname "CN=kafka,L=Cambridge,ST=Massachusetts,C=US" -storepass $PASSWORD -keypass $PASSWORD -noprompt 2>&1 | $blue
    $KEYTOOL -keystore security/exampleK.keystore.jks-deststoretype pkcs12  -alias exampleK -certreq -file security/example.cert-file-K -storepass $PASSWORD -noprompt 2>&1 | $blue
    $OPENSSL x509 -req -CA security/example.ca-cert -CAkey security/example.ca-key -in security/example.cert-file-K -out security/example.cert-signed-K -days 365 -CAcreateserial -passin pass:$PASSWORD 2>&1 | $blue
    $KEYTOOL -keystore security/exampleK.keystore.jks -deststoretype pkcs12 -alias caroot -import -file security/example.ca-cert -storepass $PASSWORD -keypass $PASSWORD -noprompt 2>&1 | $blue
    $KEYTOOL -keystore security/exampleK.keystore.jks -deststoretype pkcs12 -alias exampleK -import -file security/example.cert-signed-K -storepass $PASSWORD -keypass $PASSWORD -noprompt 2>&1 | $blue

    # vertica's keystore
    $KEYTOOL -keystore security/exampleV.keystore.jks -deststoretype pkcs12 -alias exampleV -validity 365 -keyalg RSA -genkey -dname "CN=vertica,L=Cambridge,ST=Massachusetts,C=US" -storepass $PASSWORD -keypass $PASSWORD -noprompt 2>&1 | $green
    $KEYTOOL -keystore security/exampleV.keystore.jks -deststoretype pkcs12 -alias exampleV -certreq -file security/example.cert-file-V -storepass $PASSWORD -noprompt 2>&1 | $green
    $OPENSSL x509 -req -CA security/example.ca-cert -CAkey security/example.ca-key -in security/example.cert-file-V -out security/example.cert-signed-V -days 365 -CAcreateserial -passin pass:$PASSWORD 2>&1 | $green
    $KEYTOOL -keystore security/exampleV.keystore.jks -deststoretype pkcs12 -alias caroot -import -file security/example.ca-cert -storepass $PASSWORD -keypass $PASSWORD -noprompt 2>&1 | $green
    $KEYTOOL -keystore security/exampleV.keystore.jks -deststoretype pkcs12 -alias exampleV -import -file security/example.cert-signed-V -storepass $PASSWORD -keypass $PASSWORD -noprompt 2>&1 | $green

    DOCKER_OPTS+=( -v "$PWD/security/example0.keystore.jks:/etc/keystore.jks" )
    DOCKER_OPTS+=( -v "$PWD/security/example.truststore.jks:/etc/truststore.jks" )
    DOCKER_OPTS+=( -e VKCONFIG_JVM_OPTS="-Djavax.net.ssl.keyStore=/etc/keystore.jks -Djavax.net.ssl.keyStorepassword=$PASSWORD -Djavax.net.ssl.trustStore=/etc/truststore.jks" )

  fi
  DOCKER_COMPOSE_YML=docker-compose.yml
else
  DOCKER_COMPOSE_YML=docker-compose-nossl.yml
fi

##########################
# SETUP TEST ENVIRONMENT #
##########################
if [[ $steps =~ start ]]; then

# make sure containers have been cleaned up properly
docker-compose -f $DOCKER_COMPOSE_YML rm -svf >/dev/null 2>&1 || exit $?

# start servers
# docker-compose uses colors, so don't override
docker-compose -f $DOCKER_COMPOSE_YML up -d --force-recreate

# create a directory for log output
mkdir -p log

# create and start a database
# The OSx version of bash calls the M1 chip "arm64", but if someone updates
# /bin/bash, then it will could use "aarch64" in $MACHTYPE
if [[ $MACHTYPE =~ ^aarch64 ]] || [[ $MACHTYPE =~ ^arm64 ]] ; then
  # Arm based macs crash on a memory check unless this is added
  VERTICA_ENV+=(-e VERTICA_MEMDEBUG=2)
fi
docker-compose -f $DOCKER_COMPOSE_YML exec ${VERTICA_ENV[@]} vertica /opt/vertica/bin/admintools -t create_db --database=example --password= --hosts=localhost | $green || exit $?

# create a simple table to store messages
docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -c 'create flex table KafkaFlex()' | $green || exit $?

# create an operator
docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -c 'create user JimmyKafka' | $green || exit $?

# create a resource pool
docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -c 'create resource pool Scheduler_pool plannedconcurrency 1' | $green || exit $?

# set up TLS SSL
if [[ -z $NO_SSL ]] ; then
 # docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -c 'ALTER TLS CONFIGURATION server CERTIFICATE server_cert' | $green || exit $?
:
fi

# create a couple topics
docker-compose -f $DOCKER_COMPOSE_YML exec kafka kafka-run-class.sh kafka.admin.TopicCommand --create --partitions 10 --replication-factor 1 --topic KafkaTopic1 --bootstrap-server kafka:9092 | $green || exit $?
docker-compose -f $DOCKER_COMPOSE_YML exec kafka kafka-run-class.sh kafka.admin.TopicCommand --create --partitions 10 --replication-factor 1 --topic KafkaTopic2 --bootstrap-server kafka:9092 | $green || exit $?

fi

###################
# SETUP SCHEDULER #
###################
if [[ $steps =~ setup ]]; then

# create scheduler
# set the target table
# set the parser
# set the kafka server
# define a couple sources (topics)
# define a couple microbatches
# (using one "docker run" because the startup costs add up)
docker run \
  "${DOCKER_OPTS[@]}" \
  vertica/kafka-scheduler:$VERTICA_VERSION bash -c "
    echo 'Creating scheduler schema' ; \
    vkconfig scheduler \
      --conf /etc/vkconfig.conf \
      --frame-duration 00:00:10 \
      --create \
      --operator JimmyKafka \
      --eof-timeout-ms 2000 \
      --config-refresh 00:01:00 \
      --new-source-policy START \
      --resource-pool Scheduler_pool || exit $? ; \
    echo 'Creating target table KafkaFlex' ; \
    vkconfig target --add \
      --conf /etc/vkconfig.conf \
      --target-schema public \
      --target-table KafkaFlex || exit $? ; \
    echo 'Setting parser to kafkajsonparser' ; \
    vkconfig load-spec --add \
      --conf /etc/vkconfig.conf \
      --load-spec KafkaSpec \
      --parser kafkajsonparser \
      --load-method DIRECT \
      --message-max-bytes 1000000 || exit $? ; \
    echo 'Configuring kafka cluster as kafka:9092' ; \
    vkconfig cluster --add \
      --conf /etc/vkconfig.conf \
      --cluster KafkaCluster \
      --hosts kafka:9092 || exit $? ; \
    echo 'Configuring 10 partions from topic KafkaTopic1 on kafka:9092' ; \
    vkconfig source --add \
      --conf /etc/vkconfig.conf \
      --source KafkaTopic1 \
      --cluster KafkaCluster \
      --partitions 10 || exit $? ; \
    echo 'Configuring 10 partions from topic KafkaTopic2 on kafka:9092' ; \
    vkconfig source --add \
      --conf /etc/vkconfig.conf \
      --source KafkaTopic2 \
      --cluster KafkaCluster \
      --partitions 10 || exit $? ; \
    echo 'Connecting KafkaTopic1 to table KafkaFlex' ; \
    vkconfig microbatch --add \
      --conf /etc/vkconfig.conf \
      --microbatch KafkaBatch1 \
      --add-source KafkaTopic1 \
      --add-source-cluster KafkaCluster \
      --target-schema public \
      --target-table KafkaFlex \
      --rejection-schema public \
      --rejection-table KafkaFlex_rej \
      --load-spec KafkaSpec || exit $? ; \
    echo 'Connecting KafkaTopic2 to table KafkaFlex' ; \
    vkconfig microbatch --add \
      --conf /etc/vkconfig.conf \
      --microbatch KafkaBatch2 \
      --add-source KafkaTopic2 \
      --add-source-cluster KafkaCluster \
      --target-schema public \
      --target-table KafkaFlex \
      --rejection-schema public \
      --rejection-table KafkaFlex_rej \
      --load-spec KafkaSpec || exit $? ; \
  " | $green
  if (($?)); then
    echo "Kafka Scheduler setup failed" | $red >&2
  fi
fi

#####################
# RUN THE SCHEDULER #
#####################
if [[ $steps =~ run ]]; then

# make sure it's not already running
docker rm kafka_scheduler 2>/dev/null | $green

# run this in the background
# don't color the log output becasue it can mess up the formatting
docker run \
  "${DOCKER_OPTS[@]}" \
  vertica/kafka-scheduler:$VERTICA_VERSION \
    vkconfig launch \
      --conf /etc/vkconfig.conf | $blue &
SCHEDULER_PID=$!

fi
#####################
# SEND TO KAFKA AND #
# SEE IT IN VERTICA #
#####################
if [[ $steps =~ write ]]; then

# fake loop so we can 'break'
while true; do

# write a test subject with a caffine addiction
docker-compose -f $DOCKER_COMPOSE_YML exec kafka bash -c 'echo "{\"Test Subject\":\"98101\", \"Diagnosis\":\"Caffine Addiction\"}" | kafka-console-producer.sh \
  --topic KafkaTopic1 \
  --bootstrap-server localhost:9092' | grep . | $green

# Make sure it's there
# This produces an eroneous error message, so grep is used to only print messages
docker-compose -f $DOCKER_COMPOSE_YML exec kafka kafka-console-consumer.sh --topic KafkaTopic1 --bootstrap-server localhost:9092 --from-beginning --timeout-ms 1000 | grep '^{' | $green

# wait for it to appear in vertica
delay=0
while ! docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -t -c "SELECT compute_flextable_keys_and_build_view('KafkaFlex'); SELECT Diagnosis FROM KafkaFlex_view WHERE \"Test Subject\" = '98101'" | grep Caffine >/dev/null 2>&1; do
  if ((delay++ > 20)); then
    echo "ERROR: Should have appeared within the ~10 second frame duration." | $red >&2
    break 2
  fi
  echo "Waiting ($delay) for Kafka test message containing 'Caffine'..." | $green
  sleep 1;
done

docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -c "SELECT * FROM KafkaFlex_view" | $green

# write a test subject with a cold feet problem
docker-compose -f $DOCKER_COMPOSE_YML exec kafka bash -c 'echo "{\"Test Subject\":\"99782\", \"Diagnosis\":\"Cold Feet\"}" | kafka-console-producer.sh \
  --topic KafkaTopic2 \
  --bootstrap-server localhost:9092' | grep . | $green

# Make sure it's there
docker-compose -f $DOCKER_COMPOSE_YML exec kafka kafka-console-consumer.sh --topic KafkaTopic2 --bootstrap-server localhost:9092 --from-beginning --timeout-ms 1000 | grep '^{' | $green

delay=0
while ! docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -t -c "SELECT compute_flextable_keys_and_build_view('KafkaFlex'); SELECT Diagnosis FROM KafkaFlex_view WHERE \"Test Subject\" = '99782'" | grep Cold >/dev/null 2>&1; do
  if ((delay++ > 20)); then
    echo "ERROR: Should have appeared within the ~10 second frame duration." | $red >&2
    break 2
  fi
  echo "Waiting ($delay) for Kafka test message containing 'Cold Feet'..." | $green
  sleep 1;
done

break
done

docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -c "SELECT * FROM KafkaFlex_view" | $green
if count=$(docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -t -c "SELECT count(*) FROM KafkaFlex_rej" | head -1 | sed 's/\s//g' 2>&1) && [[ $count =~ ^[0-9][0-9]*$ ]] && ((count)); then
  docker-compose -f $DOCKER_COMPOSE_YML exec vertica vsql -c "SELECT * FROM KafkaFlex_rej" | $red
fi

fi
######################
# STOP THE SCHEDULER #
######################
if [[ $steps =~ stop ]]; then

echo SHUTTING DOWN... | $green

# a graceful shutdown request
docker exec \
  --user $(id -u):$(id -g) \
  kafka_scheduler \
    killall java 2>&1 | $red >&2

delay=0
: ${SCHEDULER_PID=$(ps -ef | grep 'vkconfig_scheduler\ .*vkconfig launch' | awk '{ print $2 }')}
while kill -0 $SCHEDULER_PID >/dev/null 2>&1; do
  sleep 1;
  if ((delay++ > 20)); then
    # not so graceful
    echo "Scheduler didn't stop gracefully" | $red >&2
    docker stop kafka_scheduler 2>&1 | $red >&2
    break;
  fi
done

# This isn't necessary because --rm is used in 'docker run'
# docker rm kafka_scheduler 2>&1 | $green
# Here's how to prune old unused containers if you forget to use --rm
# docker container rm $(docker container ls -a --filter=ancestor=vertica/kafka-scheduler | tail -n +2 | awk '{ print $NF }')

fi
###############################
# DELETE THE TEST ENVIRONMENT #
###############################
if [[ $steps =~ clean ]]; then

# docker-compose uses colors, so don't override
docker-compose -f $DOCKER_COMPOSE_YML down
docker-compose -f $DOCKER_COMPOSE_YML rm -svf
fi
