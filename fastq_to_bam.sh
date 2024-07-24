#!/bin/bash

######################### Change the following ! #############################
# specify file path for reference fasta file
REF_FASTA="/path/to/human_g1k_v37_decoy.fasta"

# specify file path for sites_of_variation.vcf 
SITES_OF_VARIATION="/path/to/dbsnp_138.b37.vcf"

# specify file paths for reference files for indel realignment
INDELS_1="/path/to/1000G_phase1.indels.b37.vcf"
INDELS_2="/path/to/Mills_and_1000G_gold_standard.indels.b37.vcf"

# specify path to exome target intervals file
EXOME_INTERVALS="/path/to/Broad.human.exome.b37.interval_list"

# specify temporary directory, and make sure it has enough disk space 
# recommendation: use /sc/arion/scratch 
TEMP_DIR="/sc/arion/scratch/<username>/temp"

##############################################################################


# Function to print progress with timestamp
print_progress() {
    echo "[`date +%Y-%m-%dT%H:%M:%S`] $1"
}

# Exit immediately if a command exits with a non-zero status.
set -e

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [options] -f <reference.fa> -r <read1.fastq,read2.fastq> -o <output_prefix>

Required Arguments:
  -r <read1.fastq,read2.fastq>     Comma-separated list of two FASTQ files.
  -o <output_prefix>               Prefix for output files.

Options:
  -h                               Display this message.
  -v                               Enable verbose mode.
  --patient                        Patient id.
  --index_ref                      Run bwa_index step.
  --keep_intermediate              Keep intermediate files.
  --post_process                   Carry out post processing of BAM file after alignment.
  --threads                        Number of threads to use for bwa-mem step.
  --step                           Specify starting step.


EOF
    exit 1
}

# Variables
PATIENT=
READS=()
OUTPUT_PREFIX=
VERBOSE=0
INDEX=0
POST_PROCESS=0
KEEP_INTERMEDIATE=0
THREADS=8
STEP=0

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h) usage ;;
        -v) VERBOSE=1 ;;
        --keep_intermediate) KEEP_INTERMEDIATE=1 ;;
        --post_process) POST_PROCESS=1 ;;
        --index_ref) INDEX=1 ;;
        --threads) THREADS="$2"; shift ;;
        --step) STEP="$2"; shift ;;
        --patient) PATIENT="$2"; shift ;;
        -r) READS="$2"; shift ;;
        -o) OUTPUT_PREFIX="$2"; shift ;;
        *) echo "Error: Unkown argument/option: $1" ; usage ;;
    esac
    shift
done

# Check that mandatory arguments are provided
if [ "$STEP" -eq 0 ] && [ -z "$READS" ] || [ -z "$OUTPUT_PREFIX" ] || [ -z "$PATIENT" ]; then
    echo "Error: Not all required arguemnts provided."
    usage
fi

# Split the READS argument into an array
IFS=',' read -r -a READ_ARRAY <<< "$READS"

# Ensure exactly two read files are provided
if [ "$STEP" -eq 0 ] && [ ${#READ_ARRAY[@]} -ne 2 ]; then
    echo "Error: Exactly two read files must be specified, separated by a comma."
    usage
fi

READS_1=${READ_ARRAY[0]}
READS_2=${READ_ARRAY[1]}

# Check fastq read files
if [ "$STEP" -eq 0 ] && [ ! -f "$READS_1" ] || [ ! -f "$READS_2" ]; then
    echo "Error: One or both fastq read files do not exist or are not readable."
    exit 1
fi

# Check reference genome file
if [ ! -f "${REF_FASTA}" ]; then
    echo "Reference file ${REF_FASTA} not found!"
    exit 1
fi

basename=$(basename "$OUTPUT_PREFIX")
TEMP_DIR="$TEMP_DIR/$basename"

# If verbose mode is enabled, print the parameters
if [ $VERBOSE -eq 1 ]; then

    # Convert 1/0 to true/false for printing
    INDEX_STR=$( [ $INDEX -eq 1 ] && echo "true" || echo "false" )
    KEEP_INTERMEDIATE_STR=$( [ $KEEP_INTERMEDIATE -eq 1 ] && echo "true" || echo "false" )
    POST_PROCESS_STR=$( [ $POST_PROCESS -eq 1 ] && echo "true" || echo "false" )

    echo "---------------------------------------------"
    echo "Reference: $REF_FASTA"
    echo "Read1: $READS_1"
    echo "Read2: $READS_2"
    echo "Output Prefix: $OUTPUT_PREFIX"
    echo "Run Indexing: $INDEX_STR"
    echo "Post Processing: $POST_PROCESS_STR"
    echo "Keep Intermediate Files: $KEEP_INTERMEDIATE_STR"
    echo "Temporary Directory: $TEMP_DIR"
    echo "---------------------------------------------"
fi


#############################################################################################
#Run fastq-->bam pipeline

# Load required modules
module purge
print_progress "Loading required modules..."
module load samtools
module load bwa 
module load gatk/3.6-0
module load java
module load picard/2.2.4

# File Names
RAW_BAM="${OUTPUT_PREFIX}_raw.bam"
MARKDUP_BAM="${OUTPUT_PREFIX}_md.bam"
MARKDUP_TXT="${OUTPUT_PREFIX}_md_metrics.txt"
REALIGNED_BAM="${OUTPUT_PREFIX}_realign.bam"
RECAL="${OUTPUT_PREFIX}_recal_data.table"
FINAL_BAM="${OUTPUT_PREFIX}.bam"

# Make temporary directory if doesn't exist
[ -d "$TEMP_DIR" ] || mkdir -p "$TEMP_DIR"

echo "---------------------------------------------"
print_progress "Starting the pipeline..."
echo "---------------------------------------------"


if [ $STEP -eq 0 ] && [ $INDEX -eq 1 ]; then
# As indexing reference takes time and is only required once per reference, double check that indexing step is required:)
    if [ ! -f "$REF_FASTA.amb" ] || \
           [ ! -f "$REF_FASTA.ann" ] || \
           [ ! -f "$REF_FASTA.bwt" ] || \
           [ ! -f "$REF_FASTA.pac" ] || \
           [ ! -f "$REF_FASTA.sa" ]; then
        print_progress "Indexing the reference..."
        bwa index -a bwtsw $REF_FASTA
    else
        echo "Skipping indexing step. Ran with --index_ref flag, but index files found!"
    fi
fi

# Check that required files for post processing are accesable
if [ $POST_PROCESS -eq 1 ]; then
    if [ ! -f "$SITES_OF_VARIATION" ]; then
        echo "Error: Sites of variation ${SITES_OF_VARIATION} file not found. Required for post-processing base recalibration step."
        exit 1
    fi
    if [ ! -f "$INDELS_1" ] || [ ! -f "$INDELS_2" ]; then
        echo "Error: Indel reference file(s) not found. Required for post-processing indel realignment step."
        exit 1
    fi
fi


# TODO: add more error checking before pipeline start (maybe make a separate script for that)


# Function to get verbosity flag for a given tool
get_verbosity_flag() {
    local tool_name=$1
    if [ "$VERBOSE" -eq 0 ]; then
        case $tool_name in
            bwa) echo "-v 0" ;;
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


################################ Run the pipeline ! #####################################
#########################################################################################

# Step 1: BWA MEM Alignment and Coordinate Sorting

# Double check that index files are present
if [ $STEP -eq 0 ] && [ ! -f "$REF_FASTA.amb" ] || [ ! -f "$REF_FASTA.ann" ] || [ ! -f "$REF_FASTA.bwt" ] || [ ! -f "$REF_FASTA.pac" ] || [ ! -f "$REF_FASTA.sa" ]; then
    echo "Error: bwa index files not found. Run with the --index_ref flag."
    exit 1
fi

if [ $STEP -eq 0 ]; then
    # Construct the read group ID
    id=$(construct_read_group_id "$READS_1")
    # Construct read group sample name 
    sample=$(basename "$READS_1" | cut -d'_' -f1)
    RG="@RG\tID:${id}\tSM:${PATIENT}_${sample}\tPL:ILLUMINA"
    if [[ -z $PATIENT ]]; then  
    RG="@RG\tID:${id}\tSM:${sample}\tPL:ILLUMINA"
    fi

    print_progress "Aligning (bwa-mem) and sorting (samtools sort)"
    bwa mem -M -t $THREADS $REF_FASTA $READS_1 $READS_2 \
            -R $RG $(get_verbosity_flag bwa) | samtools sort -T $TEMP_DIR "-@${THREADS}" - -o $RAW_BAM
    wait
    STEP=1
fi

if [ $STEP -eq 1 ]; then
    if [ ! -f $RAW_BAM ]; then
        echo: "Error: MarkDuplicates starting step requires raw bam file. ${RAW_BAM} not found."
        exit 1
    fi
    # Step 2: Picard MarkDuplicates
        print_progress "Marking duplicates (Picard MarkDuplicates)..."
        java -jar $PICARD MarkDuplicates \
            I=$RAW_BAM \
            O=$MARKDUP_BAM \
            M=$MARKDUP_TXT \
            CREATE_INDEX=true \
            $(get_verbosity_flag markdup)
        wait
        STEP=2
fi

if [ $POST_PROCESS -eq 1 ] || [ $STEP -eq 2 ]; then

    if [ $STEP -eq 2 ] && [ ! -f $MARKDUP_BAM ]; then
        echo "Error: Indel realignment step requires marked dup bam file. ${MARKDUP_BAM} not found."
        exit 1
    fi

    if [ $STEP -eq 2 ]; then
        #Step 3a: GATK RealignerTargetCreator
        print_progress "Creating realigned targets (GATK RealignerTargetCreator)..."

        if [ -f "$EXOME_INTERVALS" ]; then

            java -jar $GATK_JAR \
                -T RealignerTargetCreator \
                -R $REF_FASTA \
                -L $EXOME_INTERVALS \
                -ip 100 \
                -known $INDELS_1 \
                -known $INDELS_2 \
                -I $MARKDUP_BAM \
                -o "${OUTPUT_PREFIX}.intervals"
            
        else
            java -jar $GATK_JAR \
                -T RealignerTargetCreator \
                -R $REF_FASTA \
                -known $INDELS_1 \
                -known $INDELS_2 \
                -I $MARKDUP_BAM \
                -o "${OUTPUT_PREFIX}.intervals"

        fi

        #Step 3b: GATK IndelRealigner
        print_progress "Performing local realignment around indels (GATK IndelRealigner)..."
        java -jar $GATK_JAR \
            -T IndelRealigner \
            -R $REF_FASTA \
            -I $MARKDUP_BAM \
            -known $INDELS_1 \
            -known $INDELS_2 \
            -targetIntervals "${OUTPUT_PREFIX}.intervals" \
            -o $REALIGNED_BAM

        STEP=3
    fi


    if [ $STEP -eq 3 ] && [ ! -f $REALIGNED_BAM ]; then
        echo "Error: Base recalibration step requires realigned bam file. ${REALIGNED_BAM} not found."
        exit 1
    fi

    if [ $STEP -eq 3 ]; then
        #Step 4a: GATK BaseRecalibrator
        print_progress "Recalibrating bases (GATK BaseRecalibrator)..."

        if [ -f "$EXOME_INTERVALS" ]; then
            java -jar $GATK_JAR \
                -T BaseRecalibrator \
                -L $EXOME_INTERVALS \
                -ip 100 \
                -I $REALIGNED_BAM \
                -R $REF_FASTA \
                -knownSites $SITES_OF_VARIATION \
                -o $RECAL
            wait  

            # Step 4b: GATK PrintReads
            print_progress "Applying base recalibaration (GATK PrintReads)..."
            java -jar $GATK_JAR \
                -T PrintReads \
                -I $REALIGNED_BAM \
                -L $EXOME_INTERVALS \
                -ip 100 \
                -BQSR $RECAL \
                -R $REF_FASTA \
                -o $FINAL_BAM
        
        else
            java -jar $GATK_JAR \
                -T BaseRecalibrator \
                -L $EXOME_INTERVALS \
                -ip 100 \
                -I $REALIGNED_BAM \
                -R $REF_FASTA \
                -knownSites $SITES_OF_VARIATION \
                -o $RECAL
            wait  

            # Step 4b: GATK PrintReads
            print_progress "Applying base recalibaration (GATK PrintReads)..."
            java -jar $GATK_JAR \
                -T PrintReads \
                -I $REALIGNED_BAM \
                -L $EXOME_INTERVALS \
                -ip 100 \
                -BQSR $RECAL \
                -R $REF_FASTA \
                -o $FINAL_BAM
        fi
    fi

        
else
    FINAL_BAM=$MARKDUP_BAM
fi

print_progress "Pipeline completed successfully. Output is in ${FINAL_BAM}."


# Delete temporary directory
rm -r $TEMP_DIR

# Remove intermediate files if necessary
if [ $KEEP_INTERMEDIATE -eq 0 ]; then
    print_progress "Removing intermediate files..."
    rm -f $RAW_BAM
    if [ $POST_PROCESS -eq 1 ]; then
        rm -f $MARKDUP_BAM "${MARKDUP_BAM}.bai" "${MARKDUP_BAM}.sbi" "${MARKDUP_BAM%.*}.bai" "${OUTPUT_PREFIX}.intervals" "${REALIGNED_BAM}" "${RECAL}"
    fi
fi

exit 0