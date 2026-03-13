#! /bin/sh

if command -v bazel >/dev/null 2>&1; then
    echo "has bazel tool."
else
    echo "no bazel bin found, skip."
    exit 0
fi

# Generate a per-container ~/.bazelrc for dynamic resource tuning.
: > ~/.bazelrc

if [ -d /etc/containerinfo ]; then
    cpu_limit=$(cat /etc/containerinfo/cpu_limit)
    mem_limit=$(cat /etc/containerinfo/mem_limit)
    mem_limit=$(((mem_limit / 1048576) * 9 / 10))
    echo "build --local_ram_resources=${mem_limit} --local_cpu_resources=${cpu_limit} --jobs=${cpu_limit}" >> ~/.bazelrc
fi
