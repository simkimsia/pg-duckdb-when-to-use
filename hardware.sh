#!/usr/bin/env bash
# Prints the machine and Docker specs that matter for the benchmark.
echo "date: $(date -u +%Y-%m-%dT%H:%MZ)"
if [[ "$(uname)" == "Darwin" ]]; then
  echo "machine: $(sysctl -n hw.model) ($(sysctl -n machdep.cpu.brand_string))"
  echo "cores: $(sysctl -n hw.ncpu) ($(sysctl -n hw.perflevel0.physicalcpu) performance + $(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo 0) efficiency)"
  echo "ram: $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) GB"
  echo "os: macOS $(sw_vers -productVersion)"
else
  echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
  echo "cores: $(nproc)"
  echo "ram: $(free -g | awk '/Mem:/{print $2}') GB"
  echo "os: $(uname -sr)"
fi
echo "docker: $(docker version --format '{{.Server.Version}}') ($(docker info --format '{{.OperatingSystem}}'), $(docker info --format '{{.NCPU}}') CPUs, $(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 )) GB visible)"
