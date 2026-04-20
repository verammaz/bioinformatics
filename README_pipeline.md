# Config File

```bash
cd LynchCohortPipelines
cp config.template.sh config.sh
vi config.sh
```
Specify paths and global variables in the config.sh file!


# Home Directory Structure

    .
    ├── ...
    ├── Raw/                                  # Directory with patient raw data subdirectories
    │   ├── Patient/                          # Patient directory with sample subdirectories
    │   │    ├── samplesheet.csv              # File with information about the samples. Required.   
    │   │    ├── Sample1/                     # Sample directory
    │   │    │    ├── <Sample1>.bam
    │   │    │    ├── <Sample1>.bai
    │   │    │    ├── <Sample1_vs_Tumor>.strelka.somatic_indels.vcf.gz{.tbi}
    │   │    │    ├── <Sample1_vs_Tumor>.strelka.somatic_snvs.vcf.gz{.tbi}
    │   │    │    ├── <Sample1_vs_Tumor>.mutect2.filtered.vcf.gz{.tbi}
    │   │    │    └── ...
    │   │    ├── Normal/                      # Normal directory
    │   │    │    ├── <Normal>.bam
    │   │    │    ├── <Normal>.bai
    │   │    │    └── ...
    │   │    └── ...
    │   └── ...                 
    ├── VCF/                                   # Directory for processed VCF files
    │   ├── Patient/                           # Patient directory with VCF files for each sample
    │   │    ├── <Sample1>.vcf                 # Sample VCF files have same set of variants and in same order
    │   │    ├── <Sample2>.vcf          
    │   │    ├── <Sample1>_ann.vcf             # Annotated vcf files (snpeff, varcode)
    │   │    └── ...
    │   └── ... 
    ├── PairTrees/                             # Directory for pairtree outputs                 
    │   ├── Patient/                          
    │   │    ├── <Patient>.ssm   
    │   │    ├── <Patient>.params.json
    │   │    ├── <Patient>.plottree
    │   │    ├── <Patient>.npz  
    │   │    └── ... 
    │   └── ... 
    ├── Neoantigens/                           # Directory for NoePipe neoantigen calling outputs
    │   ├── neoantigens_<Patient>.txt
    │   ├── neoantigens_other_<Patient>.txt 
    │   └── ... 
    ├── HLA/  
    │   ├── HLA_calls.txt                      # Tab-separated file with patient HLA calls   
    ├── Plots/                                 # Directory for visuals
    │   ├── TreePlots/                         # Directory for patient tree plots
    │   ├── VariantPlot/                       # Directory for patient variant plots
    │
    ├── sample_info.txt                        # Tab-separated file with sample information
    ├── patient_sex.txt                        # [Optional] file with lines ('patient' \t 'sex')    
    ├── cfit_config.json                       # Config file for CFIT
    ├── cfit_mapping.json                      # Mapping file for CFIT
    └── ... 

  
# Pipelines in this repository

Note that you should run the pipelines *per patient*.

### 1: Convert FASTQ (paired-end reads) to BAM file
[fastq --> bam readme](Fastq2Bam.md)

### 2: Variant calling (via nextflow nf-core/sarek)
[variant calling readme](VariantCall.md)

### 3: Get union of variants across samples
[union variants readme](UnionVariants.md)

### 4: Phylogenetic reconstruction (pairtree)
[pairtree readme](Pairtree.md)

### 5: Neoantigen pipeline and bioinformatic preparation of datasets for fitness modeling (NeoPipe)
[neopipe readme][NeoPipe.md]

### 6: Cancer fitness modeling (CFIT)
[cfit readme][CFIT.md]


# Additional scripts

### HLA Typing with optitype
[HLA call readme][HLAcall.md]

### Variant annotation with Varcode
```bash
cd LynchCohortPipelines
module load python3
python varcode_annotate.py -patient [PATIENT] -hdir [HDIR]
```

### Variant plotting
[figure generations readme][ForFigureGeneration.md]