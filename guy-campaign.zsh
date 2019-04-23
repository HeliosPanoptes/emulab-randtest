#!/bin/zsh
#Let's use this as an opportunity to learn some more zsh scripting


#directory the script is in.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"



# Copied from the working script
#################################################################
#################### user-configurable stuff ####################

# programs shorter than this many bytes are too boring to test
MIN_PROGRAM_SIZE=8000

# kill Csmith after this many seconds
CSMITH_TIMEOUT=90

# kill a compiler after this many seconds
COMPILER_TIMEOUT=120

# kill a compiler's output after this many seconds
PROG_TIMEOUT=8

# extra options here
CSMITH_USER_OPTIONS=""
# CSMITH_USER_OPTIONS=" --bitfields --packed-struct"

################# end user-configurable stuff ###################
#################################################################



declare -a COMPILERS
HEADER="-I ../runtime"
COMPILE_OPTIONS=""


# little wrapper to ensure proper output/timeout
function csmith {
	timeout $CSMITH_TIMEOUT $DIR/../src/csmith $@
}

function cleanup {
	# I mainly call this at the beginning of the sript so that I can have clean
	# output of that run
	rm -f $DIR/csmith.out test*.c
}

function usage {
	print "usage: guy-campaign --config <config-file> [--count <test count>]"
}

function read_config { # (configFile)
	zmodload zsh/mapfile
	COMPILERS=( "${(f)mapfile[$1]}" )
}

function generate { # (cFile)

	# run csmith until we generate a big enough program
	while : ; do
		rm -f $1
		csmith $CSMITH_USER_OPTIONS --output $1

		if [[ $(du -b $1 | cut -f1) -gt $MIN_PROGRAM_SIZE ]] {
			break
		}
	done
}

# compile a program and execute
# return code 0: normal; 
#             1: compiler crashes; 
#             2: compiler hangs; 
#             3: executable crashes; 
#             4: executable hangs;
function compile { # (compiler, cFile, outfile, currentNumber)
	program="a$4.out"
	output=$3
	rm -f $program $output

	# this funny little syntax is to allow for our input file to have compiler optimization flags built-in
	timeout $COMPILER_TIMEOUT ${=1} ${=2} ${=COMPILE_OPTIONS} ${=HEADER} -o $program > compiler.out 2>&1

	compiler_return=$?

	if [[ $compiler_return == 124 ]]; then
		#timeout
		return 2
	elif [[ $compiler_return != 0 || ! -a $program ]]; then
		#crash
		return 1
	fi

	timeout $PROG_TIMEOUT ./$program > $output
	program_return=$?

	if [[ $program_return == 124 ]]; then
		#timeout
		return 4
	elif [[ $program_return != 0 || ! -a $output ]]; then
		#crash
		return 3
	fi

	return 0


}

# return code:  -2: crashes (a likely wrong-code bug)
#               -1: hangs (not interesting if everything else does too)
#                0: normal, but found no compiler error (not interesting)
#                1: found compiler crash error(s)
#                2: found compiler wrong code error(s) 
function test { # (cFile, currentNumber)

	typeset -a hangs # keep track of which programs hang
	typeset -a checksums # keep track of checksums from programs
	output_file="out$2.log"
	return_val=0

	for compiler in $COMPILERS; do
		compile $compiler $1 $output_file $2
		compile_output=$?

		if [[ $compile_output == 1 || $compile_output == 2 ]]; then
			return 1 # compiler crash error

		elif [[ $compile_output == 3 ]]; then
			return -2 # program crash error

		elif [[ $compile_output == 4 ]]; then
			hangs+=(1)
			return_val=-1
		else
			hangs+=(0)
			checksums+=${mapfile[$output_file]}	
		fi	
	done

	for current_hang in $hangs; do
		 #check all the hang indicators against the first.
		 if [[ $current_hang != $hangs[1] ]]; then
		 	return -3 # wrong code error
		 fi
	done

	for current_checksum in $checksums; do
		if [[ $current_checksum != $checksums[1] ]]; then
		 	return 2 # wrong code error
		fi
	done

	return $return_val
}

# clean starting slate
#cleanup

# Parse args
# https://medium.com/@Drew_Stokes/bash-argument-parsing-54f3b81a6a8f

CONFIG_REQUIRED=0
COUNT=-1
PARAMS=""
while (( $# )); do
  case "$1" in
    -c|--config)
      CONFIG=$2
      CONFIG_REQUIRED=1
      shift 2
      ;;
    -n|--count)
      COUNT=$2
      shift 2
      ;;
    --) # end argument parsing
      shift
      break
      ;;
    -*|--*=) # unsupported flags
      usage
      exit 1
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done
# set positional arguments in their proper place
eval set -- "$PARAMS"

if [[ CONFIG_REQUIRED -eq 0 ]] {
	usage
	exit 1
}

read_config $CONFIG


PROGRESS=0
CRASH_BUG=0
HANGS=0
WRONGCODE_BUG=0

#loop forever if no count is provided
for (( i = 1; i != $COUNT+1; i++ )); do
	cfile="test$i.c" 
	generate $cfile

	test $cfile $i
	return_code="$?"
	# return code:  -3: hangs inconsistently (wrong-code bug)
	#               -2: crashes (a likely wrong-code bug)
    #               -1: hangs (not interesting if everything else does too)
    #                0: normal, but found no compiler error (not interesting)
    #                1: found compiler crash error(s)
    #                2: found compiler wrong code error(s)
    (( PROGRESS++ ))

    if [[ $return_code == -2 ]]; then
    	(( CRASH_BUG++ ))
    	echo "[ !! ] Crash bug on $cfile"
    elif [[ $return_code == -1 ]]; then
    	(( HANGS++ ))
    elif [[ $return_code == -3 ]]; then
    	(( HANGS++ ))
    	echo "[ !! ] Non-consistent hang on $cfile"
    elif [[ $return_code == 1 ]]; then
    	(( CRASH_BUG++ ))
    	echo "[ !! ] Compiler crash bug on $cfile"
    elif [[ $return_code == 2 ]]; then
    	(( WRONGCODE_BUG++ ))
    	echo "[!!!!] Wrong code bug on $cfile"
    else
    	#delete the files, since we don't need to look at it any more
    	output_log="out$i.log"
    	output_out="a$i.out"
    	rm -f $cfile
    	rm -f $output_log
    	rm -f $output_out

    fi 

    echo -e "[INFO] Progress: $PROGRESS\t Crashes: $CRASH_BUG\t Hangs: $HANGS\t Wrong code: $WRONGCODE_BUG"

done

#todo: autosave  results to their own directory
#   !: cluster the testing
#    : emulab
#.   : clean up the log and out files
#.   : try out xsmith
#.   














