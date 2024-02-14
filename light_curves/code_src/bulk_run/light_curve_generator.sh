#!/bin/bash

# BULK_RUN_DIR="$(dirname "$0")"
HELPER_PY="$(dirname "$0")/helper.py"
# echo "helper_py: ${HELPER_PY}"
# exit 0
# [TODO] append to all log and data files, don't overwrite

# ---- Define some functions.
kill_all_pids(){
    run_id=$1
    logsdir=$2
    logfile=$3

    # scrape log files and collect all PIDs into an array
    for file in "$logsdir"/*.log; do
        # use regex to match the number in a string with the syntax [pid=1234]
        # https://unix.stackexchange.com/questions/13466/can-grep-output-only-specified-groupings-that-match
        # ----
        # [TODO] THIS WILL FAIL ON MacOS (invalid option '-P') but I haven't found a more general solution
        # https://stackoverflow.com/questions/77662026/grep-invalid-option-p-error-when-doing-regex-in-bash-script
        # (the '-P' is required for the look-behind, '\K', which excludes "[pid=" from the returned result)
        # ----
        all_pids+=($(grep -oP '\[pid=\K\d+' $file))
    done
    
    # deduplicate the array
    pids=($(for pid in "${all_pids[@]}"; do echo $pid; done | sort --sort=numeric --unique))
    # add currently running python PIDs
    # https://stackoverflow.com/questions/21470362/find-the-pids-of-running-processes-and-store-as-an-array
    pids+=($(ps -ef | grep python | awk '{print $2}'))
    # get only values that are in both lists
    kill_pids=($(for pid in "${pids[@]}"; do echo $pid; done | sort | uniq --repeated))

    # killing processes can be dangerous. make the user confirm.
    echo "WARNING, you are about to kill all processes started by the run run_id='${run_id}'." | tee -a ${logfile}
    echo "This includes the following PIDs: ${kill_pids[@]}" | tee -a ${logfile}
    read -p "Enter 'y' to continue or any other key to abort: " continue_kill
    continue_kill="${continue_kill:-n}"
    if [ $continue_kill == "y" ]; then
        echo "Killing." | tee -a ${logfile}
        # kill each PID
        for pid in "${kill_pids[@]}"; do kill $pid; done
    else
        echo "Aborting." | tee -a ${logfile}
    fi

}

print_help_me(){
    echo "For help, call this script with the '-h' flag:"
    echo "    \$ ./$(basename $0) -h"
}

print_help_run_instructions(){
    echo "For instructions on monitoring a run and loading the output, use:"
    echo "    \$ ./$(basename $0) -i"
}

print_logs(){
    logfile=$1
    echo "-- ${logfile}:"
    cat $logfile
    echo "--"
}

print_run_instructions(){
    echo "When this script is executed it launches a run consisting of multiple jobs:"
    echo "    - one for this script"
    echo "    - one for the function that builds the object sample"
    echo "    - one for each call to an archive"
    echo
    echo "---- Check Progress ----"
    echo "There are several ways to check the progress, listed below."
    echo
    echo "1: Logs"
    echo "To check a job's progress, view its log file by setting the 'logfile' variable (you can"
    echo "copy/paste this from the script's output), then using:"
    echo "    \$ cat \$logfile"
    echo "View this script's log for high-level job info and variables to copy/paste."
    echo "View an archive's log to check its progress."
    echo
    echo "2: 'top'"
    echo "Use 'top' to monitor job activity (job PID's are in script output) and overall resource usage."
    echo
    echo "3: Output"
    echo "Once light curves are loaded, the data will be written to a parquet dataset with"
    echo "one partition for each archive."
    echo "To check which archives are done, set the 'parquet_dir' variable (copy/paste from script"
    echo "output), then use:"
    echo "    \$ ls -l \$parquet_dir"
    echo "You will see a directory for each archive that is complete."
    echo
    echo "---- Kill Jobs ----"
    echo "Kill one job:"
    echo "If a particular archive encounters problems and you need to kill its job, kill the process."
    echo "Set a 'pid' variable (copy/paste from script output), then use:"
    echo "    \$ kill \$pid"
    echo
    echo "Kill all jobs:"
    echo "If, at any point, you want to cancel all jobs launch by the run, killing every process,"
    echo "call the script again using the flags '-r' (with same value as before) and '-k'."
    echo "For example, if your run ID is 'my_run_id':"
    echo "    \$ ./$(basename $0) -r my_run_id -k"
    echo
    echo "---- Load the Light Curves (after jobs complete) ----"
    echo "Light curves will be written to a parquet dataset."
    echo "To load the data (in python, with pandas) set the 'parquet_dir' variable (copy/paste from"
    echo "script output), then use:"
    echo "    >>> df_lc = pd.read_parquet(parquet_dir)"
    echo

}

print_usage(){
    echo "---- Usage Examples ----"
    echo "  - Basic run with default options:"
    echo "    \$ ./$(basename $0) -r my_run_id "
    echo "  - Specify two papers to get sample objects from, and two archives to fetch light curves from:"
    echo "    \$ ./$(basename $0) -r run_two -l 'yang hon' -m 'gaia wise'"
    echo "  - Get ZTF light curves for 200 objects from the SDSS sample:"
    echo "    \$ ./$(basename $0) -r ztf -l SDSS -n 200 -m ztf"
    echo "  - If something went wrong with the 'ztf' run and you want to kill it:"
    echo "    \$ ./$(basename $0) -r ztf -k"
    echo
    echo "---- Available Flags ----"
    echo "Flags that require a value (defaults in parentheses):"
    echo "    -r : ID for the run. Used to label the output directory. There is no default."
    echo "         A value is required. No spaces or special characters."
    echo "    -l ('yang SDSS') : Space-separated list of literature/paper names from which to build the object sample."
    echo "    -c (true) : whether to consolidate_nearby_objects"
    echo "    -g ('{"SDSS": {"num": 10}}') : json string representing dicts with keyword arguments."
    echo "    -m ('gaia heasarc icecube wise ztf') : Space-separated list of archives from which to load light curves."
    echo "    -o (object_sample.ecsv) : File name storing the object sample."
    echo "    -p (lightcurves.parquet) : Directory name storing the light-curve data."
    echo "Flags to be used without a value:"
    echo "    -h : Print this help message."
    echo "    -i : Print instructions on monitoring a run and loading the output."
    echo "    -k : Kill the entire run by killing all jobs/processes started with the specified run ID ('-r')."
    echo
    echo "---- Instructions for Monitoring a Run ----"
    print_help_run_instructions
}

# ---- Set variable defaults.
archive_names=(core)
# yaml=helper_kwargs_defaults.yml
extra_kwargs=()
json_kwargs='{}'
kill_all_processes=false

# ---- Set variables that were passed in as script arguments.
# info about getopts: https://www.computerhope.com/unix/bash/getopts.htm#examples
while getopts r:m:j:e:hik flag; do
    case $flag in
        r) run_id=$OPTARG
            extra_kwargs+=("run_id=${OPTARG}")
            ;;
        m) archive_names=("$OPTARG");;
        # y) yaml=$OPTARG;;
        j) json_kwargs=$OPTARG;;
        h) print_usage
            exit 0
            ;;
        i) print_run_instructions
            exit 0
            ;;
        k) kill_all_processes=true;;
        e) extra_kwargs+=("$OPTARG");;
        ?) print_help_me
            exit 1
            ;;
      esac
done
# expand a archive_names shortcut value.
if [ "${archive_names[0]}" == "all" ]; then
    archive_names=($( python $HELPER_PY --build archive_names_all+l \
        --extra_kwargs ${extra_kwargs[@]} \
        --json_kwargs "$json_kwargs" ) \
    )
fi
if [ "${archive_names[0]}" == "core" ]; then
    archive_names=($( python $HELPER_PY --build archive_names_core+l \
        --extra_kwargs ${extra_kwargs[@]} \
        --json_kwargs "$json_kwargs" ) \
    )

fi

# If a run_id was not supplied, exit.
if [ -z ${run_id+x} ]; then
    echo "./$(basename $0): missing required option -- r"
    print_help_me
    exit 1
fi

# ---- Construct file paths.
base_dir=$(python $HELPER_PY --build base_dir+ --extra_kwargs ${extra_kwargs[@]} --json_kwargs "$json_kwargs")
# if HELPER_PY didn't create base_dir then something is wrong and we need to exit
if [ ! -d "$base_dir" ]; then
    echo "${base_dir} does not exist. Exiting."
    exit 1
fi
# echo "base: ${base_dir}"
parquet_dir=$(python $HELPER_PY --build parquet_dirpath+ --extra_kwargs ${extra_kwargs[@]} --json_kwargs "$json_kwargs")
# echo "parquet: ${parquet_dir}"
# base_dir=$(python $HELPER_PY --build base_dir+ --kwargs_yaml $yaml --extra_kwargs ${extra_kwargs[@]})
# parquet_dir=$(python $HELPER_PY --build parquet_dir+ --kwargs_yaml $yaml --extra_kwargs ${extra_kwargs[@]})
logsdir="${base_dir}/logs"
# echo "logs: ${logsdir}"
mkdir -p $logsdir
mylogfile="${logsdir}/$(basename $0).log"
logfiles=("$mylogfile")

{  # we will tee the output of everything below here to $mylogfile

# ---- If the user has requested to kill processes, do it and then exit.
if [ $kill_all_processes == true ]; then 
    kill_all_pids $run_id $logsdir $mylogfile
    exit 0
fi

# ---- Report basic info about the run.
echo "*********************************************************************"
echo "**                          Run starting.                          **"
echo "**                                                                 **"
echo
echo "run_id=${run_id}"
echo "output_dir=${base_dir}"
echo "This script output will also be written to logfile=${mylogfile}"

# ---- Do the run. ---- #

# ---- 1: Run job to get the object sample, if needed. Wait for it to finish.
logfile="${logsdir}/get_sample.log"
logfiles+=("$logfile")
echo
echo "Build sample is starting. logfile=${logfile}"
python $HELPER_PY --build sample \
    --extra_kwargs ${extra_kwargs[@]} \
    --json_kwargs "$json_kwargs" \
    > ${logfile} 2>&1
    # --kwargs_yaml $yaml \
echo "Build sample is done. Printing the log for convenience:"
print_logs $logfile
# exit 0

# ---- 2: Start the jobs to fetch the light curves in the background. Do not wait for them to finish.
echo
echo "Archive calls are starting."
for archive in ${archive_names[@]}; do
    logfile="${logsdir}/${archive}.log"
    logfiles+=("$logfile")
    nohup python $HELPER_PY --build lightcurves \
        --extra_kwargs ${extra_kwargs[@]} \
        --json_kwargs "$json_kwargs" \
        --archive $archive \
        > ${logfile} 2>&1 &
        # --kwargs_yaml $yaml \
    echo "[pid=${!}] ${archive} started. logfile=${logfile}"
done

# ---- 3: Print some instructions for the user, then exit.
echo
echo "Light curves are being loaded in background processes. PIDs are listed above."
echo "Once loaded, data will be written to a parquet dataset. parquet_dir=${parquet_dir}"
print_help_run_instructions
echo
echo "**                       Main script exiting.                       **"
echo "**           Jobs may continue running in the background.           **"
echo "**********************************************************************"
} | tee -a $mylogfile
