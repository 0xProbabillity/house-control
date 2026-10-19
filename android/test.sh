#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/policy-tests
"${JAVA_HOME:+$JAVA_HOME/bin/}javac" -d build/policy-tests app/src/main/java/io/github/housecontrol/ServerAddress.java tests/ServerAddressTest.java
"${JAVA_HOME:+$JAVA_HOME/bin/}java" -cp build/policy-tests io.github.housecontrol.ServerAddressTest
