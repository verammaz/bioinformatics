#!/bin/bash

##############################################
#specify file path for sites_of_variation.vcf 
SITES_OF_VARIATION="ref_b37/dbsnp_138.b37.vcf"  #(this file compatible with grch37/b37 assembly)
##############################################

# Function to print progress with timestamp
print_progress() {
    echo "[`date +%Y-%m-%dT%H:%M:%S`] $1"
}

# Load required modules
module purge
print_progress "Loading required modules..."
module load samtools >/dev/null 2>&1
module load bwa >/dev/null 2>&1
module load gatk >/dev/null 2>&1
module load java/1.8.0_66 >/dev/null 2>&1
module load picard/2.2.4 >/dev/null 2>&1

# Exit immediately if a command exits with a non-zero status.
set -e

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [options] -f <reference.fa> -r <read1.fastq,read2.fastq> -o <output_prefix>

Required Arguments:
  -f <reference.fa>                Reference genome file in FASTA format.
  -r <read1.fastq,read2.fastq>     Comma-separated list of two FASTQ files.
  -o <output_prefix>               Prefix for output files.

Options:
  -h                               Display this message.
  -v                               Enable verbose mode.
  --index_ref                      Run bwa_index step.
  --keep_intermediate              Keep intermediate files.
  --igv                            Index BAM files for IGV viewing.
  --post_process                   Carry out post processing of BAM file after alignment.


EOF
    exit 1
}

# Variables
READS=()
REF_FASTA=
OUTPUT_PREFIX=
IGV=0
VERBOSE=0
INDEX=0
POST_PROCESS=0
KEEP_INTERMEDIATE=0

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h) usage ;;
        -v) VERBOSE=1 ;;
        --keep_intermediate) KEEP_INTERMEDIATE=1 ;;
        --igv) IGV=1 ;;
        --post_process) POST_PROCESS=1 ;;
        --index_ref) INDEX=1 ;;
        -f) REF_FASTA="$2"; shift ;;
        -r) READS="$2"; shift ;;
        -o) OUTPUT_PREFIX="$2"; shift ;;
        *) echo "Error: Unkown argument/option: $1" ; usage ;;
    esac
    shift
done

# Check that mandatory arguments are provided
if [ -z "$REF_FASTA" ] || [ -z "$READS" ] || [ -z "$OUTPUT_PREFIX" ]; then
    echo "Error: Not all required arguemnts provided."
    usage
fi

# Split the READS argument into an array
IFS=',' read -r -a READ_ARRAY <<< "$READS"

# Ensure exactly two read files are provided
if [ ${#READ_ARRAY[@]} -ne 2 ]; then
    echo "Error: Exactly two read files must be specified, separated by a comma."
    usage
fi

READS_1=${READ_ARRAY[0]}
READS_2=${READ_ARRAY[1]}

# Check fastq read files
if [ ! -f "$READS_1" ] || [ ! -f "$READS_2" ]; then
    echo "Error: One or both fastq read files do not exist or are not readable."
    exit 1
fi

# Check reference genome file
if [ ! -f "${REF_FASTA}" ]; then
    echo "Reference file not found!"
    exit 1
fi


# If verbose mode is enabled, print the parameters
if [ $VERBOSE -eq 1 ]; then

    # Convert 1/0 to true/false for printing
    INDEX_STR=$( [ $INDEX -eq 1 ] && echo "true" || echo "false" )
    KEEP_INTERMEDIATE_STR=$( [ $KEEP_INTERMEDIATE -eq 1 ] && echo "true" || echo "false" )
    POST_PROCESS_STR=$( [ $POST_PROCESS -eq 1 ] && echo "true" || echo "false" )
    IGV_STR=$( [ $IGV -eq 1 ] && echo "true" || echo "false" )

    echo "---------------------------------------------"
    echo "Reference: $REF_FASTA"
    echo "Read1: $READS_1"
    echo "Read2: $READS_2"
    echo "Output Prefix: $OUTPUT_PREFIX"
    echo "Run Indexing: $INDEX_STR"
    echo "Post Processing: $POST_PROCESS_STR"
    echo "Keep Intermediate Files: $KEEP_INTERMEDIATE_STR"
    echo "Produce IGV Files: $IGV_STR"
    echo "---------------------------------------------"
fi


#############################################################################################
#Run fastq-->bam pipeline

# File Names
RAW_BAM="${OUTPUT_PREFIX}_raw.bam"
MARKDUP_BAM="${OUTPUT_PREFIX}_markdup.bam"
MARKDUP_TXT="${OUTPUT_PREFIX}_markdup_metrics.txt"
RECAL="${OUTPUT_PREFIX}_recal_data.table"
FINAL_BAM="${OUTPUT_PREFIX}_final.bam"

echo "---------------------------------------------"
print_progress "Starting the pipeline..."
echo "---------------------------------------------"

set -o pipefail 

if [ $INDEX -eq 1 ]; then
# As indexing reference takes time and is only required once per reference, double check that indexing step is required:)
    if [ ! -f "$REF_FASTA.amb" ] || \
           [ ! -f "$REF_FASTA.ann" ] || \
           [ ! -f "$REF_FASTA.bwt" ] || \
           [ ! -f "$REF_FASTA.pac" ] || \
           [ ! -f "$REF_FASTA.sa" ]; then
        print_progress "Indexing the reference..."
        bwa index -a bwtsw $REF_FASTA
    fi
fi

# Function to get verbosity flag for a given tool
get_verbosity_flag() {
    local tool_name=$1
    if [ "$VERBOSE" -eq 0 ]; then
        case $tool_name in
            bwa) echo "-v 1" ;;
            markdup) echo "VERBOSITY=ERROR" ;;
            baserecal) echo "--verbosity ERROR" ;;
            *) echo "" ;;
        esac
    else
        echo ""
    fi
}

# Function to construct the read group ID
construct_read_group_id() {
    local file=$1
    local header
    if [[ $file == *.gz ]]; then
        header=$(gunzip -c "$file" | head -n 1)
    else
        header=$(head -n 1 "$file")
    fi
    echo "$header" | cut -f 1-3 -d":" | sed 's/@//' | sed 's/:/_/g'
}


# Step 1: BWA MEM Alignment and Coordinate Sorting

# Construct the read group ID
id=$(construct_read_group_id "$READS_1")
# Construct read group sample name 
sample=$(basename "$READS_1" | cut -d'_' -f1)

print_progress "Aligning (bwa-mem) and sorting (samtools sort)"
bwa mem -M -t 8 $REF_FASTA $READS_1 $READS_2 \
        -R "@RG\tID:${id}\tSM:${sample}\tPL:ILLUMINA" $(get_verbosity_flag bwa) | samtools sort -@8 - -o $RAW_BAM
wait   

if [ $POST_PROCESS -eq 1 ]; then

    # Step 2: Picard MarkDuplicates
    print_progress "Marking duplicates (Picard MarkDuplicates)..."
    java -jar $PICARD MarkDuplicates \
        I=$RAW_BAM \
        O=$MARKDUP_BAM \
        M=$MARKDUP_TXT \
        CREATE_INDEX=true \
        $(get_verbosity_flag markdup)
    wait  

    if [ -f "$SITES_OF_VARIATION" ]; then

        if [ ! -f "${REF_FASTA%.*}.dict" ]; then
            gatk CreateSequenceDictionary -R $REF_FASTA
        fi
        if [ ! -f "${SITES_OF_VARIATION}.idx" ]; then
            gatk IndexFeatureFile -I $SITES_OF_VARIATION
        fi

        #Step 3: GATK BaseRecalibrator
        print_progress "Recalibrating bases (GATK BaseRecalibrator)..."
        gatk BaseRecalibrator \
            -I $MARKDUP_BAM \
            -R $REF_FASTA \
            --known-sites $SITES_OF_VARIATION \
            -O $RECAL \
            $(get_verbosity_flag baserecal)
        wait  

        # Step 4: GATK ApplyBQSR
        print_progress "Applying base recalibaration (GATK ApplyBQSR)..."
        gatk ApplyBQSR \
            -I $MARKDUP_BAM \
            --bqsr-recal-file $RECAL \
            -O $FINAL_BAM \
            $(get_verbosity_flag baserecal)
    
    else
        echo "WARNING: Sites of variation file $SITES_OF_VARIATION not found."
        echo "WARNING: Cannot run GATK BaseRecalibrator."
        print_progress "Terminating post processing after GATK MarkDuplicatesSpark..."
        mv $MARKDUP_BAM $FINAL_BAM
    fi
else
    mv $RAW_BAM $FINAL_BAM
fi

print_progress "Pipeline completed successfully. Output is in ${FINAL_BAM}."


# Remove intermediate files if necessary
if [ $KEEP_INTERMEDIATE -eq 0 ] && [ $POST_PROCESS -eq 1 ]; then
    print_progress "Removing intermediate files..."
    rm -f $RAW_BAM $MARKDUP_BAM "${MARKDUP_BAM%.*}.bai" $MARKDUP_TXT $RECAL 
fi

# Index _raw.bam file (other .bam outputs indexed by post-processing tools)
if [ $IGV -eq 1 ] && [ $POST_PROCESS -eq 0]; then
    samtools index $FINAL_BAM
fi


exit 1
