#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/rrna-ampliseq
========================================================================================
 nf-core/rrna-ampliseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/rrna-ampliseq
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    log.info"""
    =========================================
     nf-core/rrna-ampliseq v${workflow.manifest.version}
    =========================================
    
    Usage:

    The minimal command for running the pipeline is as follows:
    nextflow run qiime2.nf --reads "data/*_L001_R{1,2}_001.fastq.gz" --FW_primer GTGYCAGCMGCCGCGGTAA --RV_primer GGACTACNVGGGTWTCTAAT --metadata "$PWD/data/Metadata.tsv"

    The test command for running the pipeline is as follows:
    nextflow run qiime2.nf --minimumTest

    Required arguments:
      --reads [Path to folder]      Folder containing Casava 1.8 paired-end demultiplexed fastq files: *_L001_R{1,2}_001.fastq.gz
      --FW_primer [str]             Forward primer sequence
      --RV_primer [str]             Reverse primer sequence
      --metadata                    Absolute path to metadata sheet

    Filters:
      --exclude_taxa [str]          Comma seperated list of unwanted taxa (default: "mitochondria,chloroplast")
                                    To skip filtering use "none"

    Cutoffs:
      --retain_untrimmed            Cutadapt will retain untrimmed reads
      --trunclenf [int]             DADA2 read truncation value for forward strand
      --trunclenr [int]             DADA2 read truncation value for reverse strand
      --trunc_qmin [int]            If --trunclenf and --trunclenr are not set, 
                                    these values will be automatically determined using 
                                    this mean quality score (not preferred) (default: 25)

    References:                     If you have trained a compatible classifier before
      --classifier                  Path to QIIME2 classifier file (typically *-classifier.qza)

    Statistics:
      --metadata_category           Diversity indices will be calculated using these groupings in the metadata sheet,
                                    all suitable columns in the metadata sheet will be used if not specified.
                                    Suitable are columns which are categorical (not numerical) and have multiple  
                                    different values which are not all unique.

    Other options:
      --untilQ2import               Skip all steps after importing into QIIME2, used for visually choosing DADA2 parameter
      --Q2imported [Path]           Path to imported reads (e.g. "demux.qza"), used after visually choosing DADA2 parameter
      --onlyDenoising               Skip all steps after denoising, produce only sequences and abundance tables on ASV level

    Skipping steps:
      --skip_fastqc                 Skip FastQC
      --skip_alpha_rarefaction      Skip alpha rarefaction
      --skip_taxonomy               Skip taxonomic classification
      --skip_barplot                Skip producing barplot
      --skip_abundance_tables       Skip producing any relative abundance tables
      --skip_diversity_indices      Skip alpha and beta diversity analysis
      --skip_ancom                  Skip differential abundance testing     

    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Configurable variables
params.name = false
params.multiqc_config = "$baseDir/conf/multiqc_config.yaml"
params.email = false
params.plaintext_email = false

multiqc_config = file(params.multiqc_config)
output_docs = file("$baseDir/docs/output.md")

// Defines all parameters that are independent of a test run
params.trunc_qmin = 25 //to calculate params.trunclenf and params.trunclenr automatically
params.trunclenf = false
params.trunclenr = false
params.metadata_category = false
params.qiimeimage = "$baseDir/qiime2_2018.6.simg"
params.tree_cores = 2
params.diversity_cores = 2
params.retain_untrimmed = false
params.exclude_taxa = "mitochondria,chloroplast"
params.keepIntermediates = false

//Database specific parameters
//currently only this is compatible with process make_SILVA_132_16S_classifier
params.silva = "https://www.arb-silva.de/fileadmin/silva_databases/qiime/Silva_132_release.zip"
params.dereplication = 90 //90 for test run only, for real data this has to be set to 99.


/*
 * Defines pipeline steps
 */
params.untilQ2import = false

params.Q2imported = false
if (params.Q2imported) {
    params.skip_fastqc = true
    params.skip_multiqc = true
    //Set up channel
    Channel.fromFile("${params.Q2imported}")
           .into { ch_qiime_demux }
} else {
    params.skip_fastqc = false
    params.skip_multiqc = false
}

params.onlyDenoising = false
if (params.onlyDenoising || params.untilQ2import) {
    params.skip_abundance_tables = true
    params.skip_barplot = true
    params.skip_taxonomy = true
    params.skip_alpha_rarefaction = true
    params.skip_diversity_indices = true
    params.skip_ancom = true
} else {
    params.skip_abundance_tables = false
    params.skip_barplot = false
    params.skip_taxonomy = false
    params.skip_alpha_rarefaction = false
    params.skip_diversity_indices = false
    params.skip_ancom = false
}

/*
 * Sanity check input values
 * need to be extended eventually
 */
if (!params.Q2imported && (!params.FW_primer || !params.RV_primer || !params.metadata || !params.reads)) {
    println "${params.Q2imported}"
    println "\nERROR: Missing required input --Q2imported OR --FW_primer / --RV_primer / --metadata\n"
    helpMessage()
    exit 1
}


// AWSBatch sanity checking
if(workflow.profile == 'awsbatch'){
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    if (!workflow.workDir.startsWith('s3') || !params.outdir.startsWith('s3')) exit 1, "Specify S3 URLs for workDir and outdir parameters on AWSBatch!"
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

// Check workDir/outdir paths to be S3 buckets if running on AWSBatch
// related: https://github.com/nextflow-io/nextflow/issues/813
if( workflow.profile == 'awsbatch') {
    if(!workflow.workDir.startsWith('s3:') || !params.outdir.startsWith('s3:')) exit 1, "Workdir or Outdir not on S3 - specify S3 Buckets for each to run on AWSBatch!"
}

// Header log info
// TODO lets test this too - need to add more stuff as well here
log.info """=======================================================
                                          ,--./,-.
          ___     __   __   __   ___     /,-._.--~\'
    |\\ | |__  __ /  ` /  \\ |__) |__         }  {
    | \\| |       \\__, \\__/ |  \\ |___     \\`-._,-`-,
                                          `._,._,\'

nf-core/rrna-ampliseq v${manifest.pipelineVersion}"
======================================================="""
def summary = [:]
summary['Pipeline Name']  = 'nf-core/rrna-ampliseq'
summary['Pipeline Version'] = manifest.pipelineVersion
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Reads']        = params.reads
summary['Data Type']    = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Max Memory']   = params.max_memory
summary['Max CPUs']     = params.max_cpus
summary['Max Time']     = params.max_time
summary['Output dir']   = params.outdir
summary['Working dir']  = workflow.workDir
summary['Container Engine'] = workflow.containerEngine
if(workflow.containerEngine) summary['Container'] = workflow.container
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Working dir']    = workflow.workDir
summary['Output dir']     = params.outdir
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
if(workflow.profile == 'awsbatch'){
   summary['AWS Region'] = params.awsregion
   summary['AWS Queue'] = params.awsqueue
}
if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="


def create_workflow_summary(summary) {

    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-rrna-ampliseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/rrna-ampliseq Workflow Summary'
    section_href: 'https://github.com/nf-core/rrna-ampliseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}


/*
 * Parse software version numbers
 */
process get_software_versions {

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml

    script:
    """
    echo $manifest.pipelineVersion > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}


if (!params.Q2imported){

    /*
    * Create a channel for input read files
    */
    if(params.readPaths){
        if(params.singleEnd){
            Channel
                .from(params.readPaths)
                .map { row -> [ row[0], [file(row[1][0])]] }
                .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
                .into { ch_read_pairs; ch_read_pairs_fastqc }
        } else {
            Channel
                .from(params.readPaths)
                .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
                .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
                .into { ch_read_pairs; ch_read_pairs_fastqc }
        }
    } else {
        Channel
            .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
            .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --singleEnd on the command line." }
            .into { ch_read_pairs; ch_read_pairs_fastqc }
    }
	/*
	 * fastQC
	 */
	process fastqc {
	    publishDir "${params.outdir}/fastQC", mode: 'copy',
		saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

	    input:
	    set val(name), file(reads) from ch_read_pairs_fastqc

	    output:
	    file "*_fastqc.{zip,html}" into ch_fastqc_results

	    when:
	    !params.skip_fastqc

	    script: 
	    """
        fastqc -q ${reads}
	    """
	}

	/*
	 * multiQC
	 */
	process multiqc {
	    publishDir "${params.outdir}/MultiQC", mode: 'copy'

	    input:
	    file ('fastqc/*') from ch_fastqc_results.collect()
        file ('cutadapt/*') from ch_fastq_cutadapt_log.collect()

	    output:
	    file "*multiqc_report.html" into multiqc_report
	    file "*_data"

	    when:
	    !params.skip_multiqc

	    script:
	    """
	    multiqc --force --interactive .
	    """
	}

	/*
	 * Trim each read-pair with cutadapt
	 */
    
	process trimming {  
	    publishDir "${params.outdir}/trimmed", mode: 'copy',
            saveAs: {filename -> 
            if (filename.indexOf(".gz") == -1) "logs/$filename"
            else if(filename.keepIntermediates) filename 
            else null}
	  
	    input:
	    set pair_id, file(reads) from read_pairs
	  
	    output:
        file "${reads.baseName}" into ch_fastq_trimmed
        file "cutadapt_log_*.txt" into ch_fastq_cutadapt_log

	    script:
	    if( params.retain_untrimmed == false ){ 
		    discard_untrimmed = "--discard-untrimmed"
	    } else {
		    discard_untrimmed = ""
	    }
	  
	    """
	    cutadapt -g ${params.FW_primer} -G ${params.RV_primer} $discard_untrimmed -o "${reads.baseName}".R1.fastq.gz -p "${reads.baseName}".R2.fastq.gz ${reads[0]} ${reads[1]} 2> cutadapt_log_"${reads.baseName}".txt
	    """
	}


	/*
	 * Import trimmed files into QIIME2 artefact
	 */
	process qiime_import {
        publishDir "${params.outdir}/qiime_demux", mode: 'copy', 
        saveAs: {params.keepIntermediates ? filename : null}

	    input:
	    file(trimmed) from ch_fastq_trimmed.collect() 

	    output:
	    file "demux.qza" into ch_qiime_demux

	    when:
	    !params.Q2imported
	  
	    """
	    qiime tools import  \
		--type 'SampleData[PairedEndSequencesWithQuality]'  \
		--input-path $trimmed  \
		--source-format CasavaOneEightSingleLanePerSampleDirFmt  \
		--output-path demux.qza
	    """
	}

}


/*
 * Download, unpack, extract and train classifier
 * CURRENTLY TEST CLASSIFIER, for real data: replace "dereplication=90" with "dereplication=99"
 * Requirements with "dereplication=99": 1 core (seems not to scale with more?), ~35 Gb mem, ~2:15:00 walltime
 */

if( !params.classifier ){
	process make_SILVA_132_16S_classifier {
        publishDir "${params.outdir}/DB/", mode: 'copy', 
        saveAs: {params.keepIntermediates ? filename : null}
        //TODO Only keep files we really need (*.qza)

	    output:
	    file '*.qza' into ch_qiime_classifier

	    when:
	    !params.onlyDenoising

	    script:
	  
	    """
	    unzip Silva_132_release.zip

        fasta="SILVA_132_QIIME_release/rep_set/rep_set_16S_only/"${params.dereplication}"/silva_132_"${params.dereplication}"_16S.fna"
        taxonomy="SILVA_132_QIIME_release/taxonomy/16S_only/"${params.dereplication}"/consensus_taxonomy_7_levels.txt"

	    ### Import
	    qiime tools import --type 'FeatureData[Sequence]' 
		--input-path fasta 
		--output-path ref-seq.qza
	    qiime tools import --type 'FeatureData[Taxonomy]' 
		--source-format HeaderlessTSVTaxonomyFormat 
		--input-path taxonomy 
		--output-path ref-taxonomy.qza

	    #Extract sequences based on primers
	    qiime feature-classifier extract-reads \
		--i-sequences ref-seq.qza \
		--p-f-primer ${params.FW_primer} \
		--p-r-primer ${params.RV_primer} \
		--o-reads ${params.FW_primer}-${params.RV_primer}-ref-seq.qza

	    #Train classifier
	    qiime feature-classifier fit-classifier-naive-bayes \
		--i-reference-reads ${params.FW_primer}-${params.RV_primer}-ref-seq.qza \
		--i-reference-taxonomy ref-taxonomy.qza \
		--o-classifier ${params.FW_primer}-${params.RV_primer}-classifier.qza \
		--verbose

	    """
	}
} else {
    Channel.fromFile("${params.classifier}")
           .into { ch_qiime_classifier }
}


/*
 * Import trimmed files into QIIME2 artefact
 */
if( !params.Q2imported ){
	process qiime_demux_visualize { 
        publishDir "${params.outdir}/qiime2-imported", mode: 'copy',
		saveAs: {filename -> 
            if(filename.indexOf(".csv")) filename
            else if (filename.indexOf("*.qzv")) filename 
            else if (filename.indexof('demux/*')) filename
            else null }

	    input:
	    file demux from ch_qiime_demux

	    output:
        file("*-seven-number-summaries.csv") into csv_demux
	  
	    """
	    qiime demux summarize 
		--i-data $demux 
		--o-visualization demux.qzv

	    qiime tools export demux.qzv --output-dir demux
	    """
	}
} else {
	process qiime_importdemux_visualize { 
        publishDir "${params.outdir}/qiime2-imported", mode: 'copy',
		saveAs: {filename -> 
            if(filename.indexOf(".csv")) filename
            else if (filename.indexOf("*.qzv")) filename 
            else null }

	    output:
	    file("*-seven-number-summaries.csv") into csv_demux
	  
	    """
	    qiime demux summarize \
		--i-data ${params.Q2imported} \
		--o-visualization demux.qzv

	    qiime tools export demux.qzv --output-dir demux
	    """
	}
}


/*
 * Determine params.trunclenf and params.trunclenr where the median quality value drops below params.trunc_qmin
 * "Warning massage" and "Success massage" should be printed but interferes with output: stdout
 */
process dada_trunc_parameter { 
    //echo true

    input:
    val summary_demux from csv_demux 

    output:
    stdout dada_trunc

    when:
    !params.untilQ2import

    script:
    if( !params.trunclenf || !params.trunclenr )

	    """
	    CUTOFF=()

	    IFS=\", \" read -r -a array_demux <<< \"$summary_demux\" #convert to array
	    #echo array_demux \${array_demux[@]}

	    for qfile in \${array_demux[@]}
	    do
		#read and convert to array
		string=\$(head -6 \$qfile | tail -1) #row 6 is median
		string=\${string//\"50%,\"/} #remove first field that indicate its a median value
		IFS=\", \" read -r -a median <<< \"\$string\" #convert to array
		median=(\"\${median[@]/\\.[0-9]*}\") #truncate floats to integers

		#find first occurence of quality below threshold
		for index in \${!median[@]}; do
		cutoff=\$index
		if (( \${median[index]} < ${params.trunc_qmin} )); then cutoff=\$((\$index - 1)) && break; fi;
		done
		CUTOFF+=(\$cutoff)
	    done

	    #Warning massage
	    #echo \"WARNING: no DADA2 cutoffs were specified, therefore reads will be truncated where median quality drops below ${params.trunc_qmin}.\"
	    #echo \"This does not account for required overlap for merging, therefore DADA2 might fail. In any case remember to check DADA2 merging statistics!\"

	    #Error and exit if too short
	    totallength=\$((\${CUTOFF[0]} + \${CUTOFF[1]}))
	    if (( \$totallength < 10 )); then 
	    echo \"ERROR: Total read pair length is \$totallength and below 10, this is definitely too low.\"
	    echo \"Chosen cutoffs would be forward: \${CUTOFF[0]}, reverse \${CUTOFF[1]}\"
	    echo \"Please check quality values and read length manually and provide appropriate DADA2 truncation parameters.\"
	    echo \"Exiting now!\"
	    exit
	    fi

	    #Success message
	    #echo \"Using cutoffs are forward: \${CUTOFF[0]}, reverse \${CUTOFF[1]}\"

	    printf \${CUTOFF[0]},\${CUTOFF[1]}
	    #CUTOFF <- paste(CUTOFF, collapse=",")
	    #cat(CUTOFF)
	    """
    else
	    """
	    printf "${params.trunclenf},${params.trunclenr}"
	    """
}

 
/*
 * Find ASVs with DADA2 for single sequencing run
 * Requirements: as many cores as possible (limiting step here!), ??? mem, walltime scales with no. of reads and samples (~15 min to 30 hours)
 */
process dada_single { 
    echo true

    input:
    val demux from qiime_demux
    val trunc from dada_trunc

    output:
    val "table_unfiltered.qza" into qiime_table_raw
    val "rep-seqs_unfiltered.qza" into qiime_repseq_raw
    val "feature-table.tsv" into tsv_table_raw

    when:
    !params.untilQ2import

    """
    IFS=',' read -r -a trunclen <<< \"$trunc\"
    echo run DADA on $demux with truncation values fw: \${trunclen[0]} and rv: \${trunclen[1]}

    #denoise samples with DADA2 and produce
    qiime dada2 denoise-paired  \
	--i-demultiplexed-seqs $demux  \
	--p-trunc-len-f \${trunclen[0]} \
	--p-trunc-len-r \${trunclen[1]} \
	--p-n-threads ${process.cpus}  \
	--o-table table_unfiltered.qza  \
	--o-representative-sequences rep-seqs_unfiltered.qza  \
	--o-denoising-stats stats.qza \
	--verbose

    #produce dada2 stats "${params.outdir}/dada_stats/stats.tsv"
    qiime tools export stats.qza \
	--output-dir ${params.outdir}/dada_stats

    #produce raw count table in biom format "${params.outdir}/table_unfiltered/feature-table.biom"
    qiime tools export table_unfiltered.qza  \
	--output-dir ${params.outdir}/table_unfiltered

    #produce raw count table
    biom convert -i ${params.outdir}/table_unfiltered/feature-table.biom \
	-o ${params.outdir}/table_unfiltered/feature-table.tsv  \
	--to-tsv

    #produce represenatative sequence fasta file
    qiime feature-table tabulate-seqs  \
	--i-data rep-seqs_unfiltered.qza  \
	--o-visualization rep-seqs_unfiltered.qzv
    qiime tools export rep-seqs_unfiltered.qzv  \
	--output-dir ${params.outdir}/rep_seqs_unfiltered

    #convert to relative abundances
    qiime feature-table relative-frequency \
	--i-table table_unfiltered.qza \
	--o-relative-frequency-table relative-table-ASV_unfiltered.qza

    #export to biom
    qiime tools export relative-table-ASV_unfiltered.qza \
	--output-dir rel-table_unfiltered

    #copy biom to result folder
    cp rel-table_unfiltered/feature-table.biom ${params.outdir}/table_unfiltered/rel-feature-table.biom

    #convert to tab seperated text file
    biom convert \
	-i rel-table_unfiltered/feature-table.biom \
	-o ${params.outdir}/table_unfiltered/rel-feature-table.tsv --to-tsv

    """
}

/*
 * Assign taxonomy to ASV sequences
 * Requirements: many cores, ~35 Gb mem, walltime scales with no. of ASV and ${params.classifier} = trained_classifier size (~15 min to several hours)
 * USE NXF feature of file size introduced in 0.32.0 here!!!
 */
process classifier { 
    echo true

    input:
    val table from qiime_table_raw
    val repseq from qiime_repseq_raw
    val trained_classifier from qiime_classifier

    output:
    val "taxonomy.qza" into qiime_taxonomy
    val "${params.outdir}/taxonomy/taxonomy.tsv" into tsv_taxonomy

  
    """
    qiime feature-classifier classify-sklearn  \
	--i-classifier $trained_classifier  \
	--p-n-jobs ${process.cpus}  \
	--i-reads $repseq  \
	--o-classification taxonomy.qza  \
	--verbose

    qiime metadata tabulate  \
	--m-input-file taxonomy.qza  \
	--o-visualization taxonomy.qzv  \
	--verbose

    #produce "${params.outdir}/taxonomy/taxonomy.tsv"
    qiime tools export taxonomy.qza  \
	--output-dir ${params.outdir}/taxonomy

    qiime tools export taxonomy.qzv  \
	--output-dir ${params.outdir}/taxonomy
    """
}

/*
 * Filter out unwanted/off-target taxa
 */
if (params.exclude_taxa == "none") {
	process skip_filter_taxa {
	    echo true

	    input:
	    val table from qiime_table_raw
	    val repseq from  qiime_repseq_raw

	    output:
	    val "$table" into qiime_table
	    val "$repseq" into qiime_repseq

	    script:
	  
	    """
	    echo dont exclude any taxa
	    """
	}

} else {
	process filter_taxa {
	    echo true

	    input:
	    val table from qiime_table_raw
	    val repseq from  qiime_repseq_raw
	    val taxonomy from qiime_taxonomy

	    output:
	    val "filtered-table.qza" into qiime_table
	    val "filtered-sequences.qza" into qiime_repseq

	    script:
	  
	    """
	    echo exclude taxa ${params.exclude_taxa}
	    #filter sequences
	    qiime taxa filter-seqs \
		--i-sequences $repseq \
		--i-taxonomy $taxonomy \
		--p-exclude ${params.exclude_taxa} \
		--p-mode contains \
		--o-filtered-sequences filtered-sequences.qza
	    echo produced filtered-sequences.qza

	    #filter abundance table
	    qiime taxa filter-table \
		--i-table $table \
		--i-taxonomy $taxonomy \
		--p-exclude ${params.exclude_taxa} \
		--p-mode contains \
		--o-filtered-table filtered-table.qza
	    echo produced filtered-table.qza
	    """
	}
}

/*
 * Export qiime artefacts from filtered dada output
 */
process export_filtered_dada_output { 
    echo true

    input:
    val table from qiime_table
    val repseq from qiime_repseq

    output:
    val "${params.outdir}/rep_seqs/sequences.fasta" into fasta_repseq
    val "${params.outdir}/table/feature-table.tsv" into tsv_table

    """
    #produce raw count table in biom format "${params.outdir}/table/feature-table.biom"
    qiime tools export $table  \
	--output-dir ${params.outdir}/table

    #produce raw count table "${params.outdir}/table/feature-table.tsv"
    biom convert -i ${params.outdir}/table/feature-table.biom \
	-o ${params.outdir}/table/feature-table.tsv  \
	--to-tsv

    #produce representative sequence fasta file "${params.outdir}/rep_seqs/sequences.fasta"
    qiime feature-table tabulate-seqs  \
	--i-data $repseq  \
	--o-visualization rep-seqs.qzv
    qiime tools export rep-seqs.qzv  \
	--output-dir rep_seqs
    """
}

/*
 * Report stats after taxa filtering
 */
process export_filtered_dada_output { 
    echo true

    input:
    val unfiltered_table from tsv_table_raw
    val filtered_table from tsv_table

    output:
    val "count_table_filter_stats.csv" into csv_filter_stats
    
    """
    count_table_filter_stats.py $unfiltered_table $filtered_table
    """
}

/*
 * Export relative abundance tables on ASV level
 */
process RelativeAbundanceASV { 
    echo true

    input:
    val table from qiime_table

    output:
    val "${params.outdir}/rel-table-ASV.tsv" into tsv_relASV_table

    when:
    !params.skip_abundance_tables

    """
    ##onASV level

    #convert to relative abundances
    qiime feature-table relative-frequency \
	--i-table $table \
	--o-relative-frequency-table relative-table-ASV.qza

    #export to biom
    qiime tools export relative-table-ASV.qza --output-dir relative-table-ASV

    #convert to tab seperated text file "${params.outdir}/rel-table-ASV.tsv"
    biom convert -i relative-table-ASV/feature-table.biom 
	-o rel-table-ASV.tsv --to-tsv
    """
}


/*
 * Export relative abundance tables based on taxonomic levels
 */
process RelativeAbundanceReducedTaxa { 
    echo true

    input:
    val table from qiime_table
    val taxonomy from qiime_taxonomy

    when:
    !params.skip_abundance_tables && !params.skip_taxonomy

    """
    ##on several taxa level

    array=( 2 3 4 5 6 7 )
    for i in \${array[@]}
    do
	#collapse taxa
	qiime taxa collapse \
		--i-table $table \
		--i-taxonomy $taxonomy \
		--p-level \$i \
		--o-collapsed-table table-\$i.qza
	#convert to relative abundances
	qiime feature-table relative-frequency \
		--i-table table-\$i.qza \
		--o-relative-frequency-table relative-table-\$i.qza
	#export to biom
	qiime tools export relative-table-\$i.qza \
		--output-dir relative-table-\$i
	#convert to tab seperated text file
	biom convert \
		-i relative-table-\$i/feature-table.biom \
		-o ${params.outdir}/rel-table-\$i.tsv --to-tsv
    done

    """
}


/*
 * Produce a bar plot
 */
process barplot { 
    echo true

    input:
    val table from qiime_table
    val taxonomy from qiime_taxonomy

    when:
    !params.skip_barplot && !params.skip_taxonomy
  
    """
    qiime taxa barplot  \
	--i-table $table  \
	--i-taxonomy $taxonomy  \
	--m-metadata-file ${params.metadata}  \
	--o-visualization taxa-bar-plots.qzv  \
	--verbose

    qiime tools export taxa-bar-plots.qzv  \
	--output-dir ${params.outdir}/barplot
    """
}

/*
 * Produce a rooted tree
 * Requirements: many cores ${params.tree_cores}, ??? mem, walltime scales with no. of ASV
 */
process tree { 
    echo true

    input:
    val repseq from qiime_repseq

    output:
    val "rooted-tree.qza" into qiime_tree

    when:
    !params.skip_diversity_indices || !params.skip_alpha_rarefaction

  
    """
    qiime alignment mafft \
	--i-sequences $repseq \
	--o-alignment aligned-rep-seqs.qza \
	--p-n-threads ${params.tree_cores}

    qiime alignment mask \
	--i-alignment aligned-rep-seqs.qza \
	--o-masked-alignment masked-aligned-rep-seqs.qza

    qiime phylogeny fasttree \
	--i-alignment masked-aligned-rep-seqs.qza \
	--p-n-threads ${params.tree_cores} \
	--o-tree unrooted-tree.qza

    qiime phylogeny midpoint-root \
	--i-tree unrooted-tree.qza \
	--o-rooted-tree rooted-tree.qza

    qiime tools export rooted-tree.qza  \
	--output-dir ${params.outdir}/tree
    """
}


/*
 * Alpha-rarefaction
 */
process alpha_rarefaction { 
    echo true

    input:
    val table from qiime_table
    val tree from qiime_tree
    val stats from tsv_table

    when:
    !params.skip_alpha_rarefaction

    """
    #define values for alpha-rarefaction
    maxdepth=\$(count_table_minmax_reads.py $stats maximum 2>&1)

    #check values
    if [ \"\$maxdepth\" -gt \"75000\" ]; then maxdepth=\"75000\"; fi
    if [ \"\$maxdepth\" -gt \"5000\" ]; then maxsteps=\"250\"; else maxsteps=\$((maxdepth/20)); fi
    echo \"use the maximum depth of \$maxdepth (found in \"$stats\") and \$maxsteps steps"

    qiime diversity alpha-rarefaction  \
	--i-table $table  \
	--i-phylogeny $tree  \
	--p-max-depth \$maxdepth  \
	--m-metadata-file ${params.metadata}  \
	--p-steps \$maxsteps  \
	--p-iterations 10  \
	--o-visualization alpha-rarefaction.qzv

    qiime tools export alpha-rarefaction.qzv  \
	--output-dir ${params.outdir}/alpha-rarefaction
    """
}

/*
 * Combine abundances, sequences and taxonomic classification into one table with R
 */
process combinetable { 
    echo true

    input:
    val TABLE from tsv_relASV_table
    val SEQ from fasta_repseq
    val TAXONOMY from tsv_taxonomy

    when:
    !params.skip_abundance_tables && !params.skip_taxonomy

    """
    combineTable.r $TABLE $SEQ $TAXONOMY
    """
}

/*
 * Compute diversity matrices
 */
process diversity_core { 
    echo true

    input:
    val table from qiime_table
    val tree from qiime_tree
    val stats from tsv_table

    output:
    val "core" into qiime_diversity_core

    when:
    !params.skip_diversity_indices

    """
    #define values for diversity_core
    mindepth=\$(count_table_minmax_reads.py $stats minimum 2>&1)

    #check values
    if [ \"\$mindepth\" -lt \"10000\" -a \"\$mindepth\" -gt \"5000\" ]; then echo \"WARNING! \$mindepth is quite small for rarefaction!\" ; fi
    if [ \"\$mindepth\" -lt \"5000\" -a \"\$mindepth\" -gt \"1000\" ]; then echo \"WARNING! \$mindepth is very small for rarefaction!\" ; fi
    if [ \"\$mindepth\" -lt \"1000\" ]; then echo \"ERROR! \$mindepth is too small for rarefaction!\" ; fi
    echo \"use the minimum depth of \$mindepth (found in \"$stats\")\"

    #run diversity core
    qiime diversity core-metrics-phylogenetic \
	--m-metadata-file ${params.metadata} \
	--i-phylogeny $tree \
	--i-table $table \
	--p-sampling-depth \$mindepth \
	--output-dir core \
	--p-n-jobs ${params.diversity_cores} \
	--verbose
    """
}

/*
 * Compute alpha diversity indices
 */
process alpha_diversity { 
    echo true

    input:
    val core from qiime_diversity_core

    output:
    val "${params.outdir}/alpha-diversity" into qiime_alphadiversity


    """
    method=( \"faith_pd_vector\" \"evenness_vector\" \"shannon_vector\" \"observed_otus_vector\" )
    for i in \"\${method[@]}\"
    do
	qiime diversity alpha-group-significance \
                --i-alpha-diversity $core/\$i.qza \
                --m-metadata-file ${params.metadata} \
                --o-visualization $core/\$i.qzv \
                --verbose
	qiime tools export $core/\$i.qzv \
                --output-dir ${params.outdir}/alpha-diversity/\$i
    done
    """
}

/*
 * Capture all possible metadata categories for statistics
 * TODO MISSING INPUT CATEGORIES / FILES ? 
 */
process metadata_category_all { 

    output:
    stdout meta_category_all

    when:
    !params.skip_ancom || !params.skip_diversity_indices
    when:
    !params.untilQ2import && !params.onlyDenoising

    script:
    if( !params.metadata_category )
	    """
	    metadataCategory.r $input
	    """
    else
	    """
	    printf ${params.metadata_category}
	    """
}

/*
 * Capture all pairwise metadata categories for statistics
 */
process metadata_category_pairwise { 

    input:
    val meta_all from meta_category_all

    output:
    stdout meta_category_pairwise

    when:
    !params.skip_diversity_indices

    """
    metadataCategoryPairwise.r $input
    """
}



/*
 * Compute beta diversity indices
 */
process beta_diversity { 
    echo true

    input:
    val core from qiime_diversity_core
    val meta from meta_category_pairwise

    output:
    val "${params.outdir}/beta-diversity" into qiime_betadiversity

    """
    method=( \"unweighted_unifrac_distance_matrix\" \"bray_curtis_distance_matrix\" \"weighted_unifrac_distance_matrix\" \"jaccard_distance_matrix\" )

    IFS=',' read -r -a metacategory <<< \"$meta\"
    echo perform beta-diversity tests on "\${metacategory[@]}\"

    for i in \"\${method[@]}\"
    do
	for j in \"\${metacategory[@]}\"
	do
		qiime diversity beta-group-significance \
		        --i-distance-matrix $core/\$i.qza \
		        --m-metadata-file ${params.metadata} \
		        --m-metadata-column \"\$j\" \
		        --o-visualization $core/\$i-\$j.qzv \
		        --p-pairwise \
		        --verbose
		qiime tools export $core/\$i-\$j.qzv \
		        --output-dir ${params.outdir}/beta-diversity/\$i-\$j
	done
    done
    """
}

/*
 * Compute beta diversity ordination
 */
process beta_diversity_ordination { 
    echo true

    input:
    val core from qiime_diversity_core

    """
    method=( \"unweighted_unifrac_pcoa_results\" \"weighted_unifrac_pcoa_results\" \"jaccard_pcoa_results\" \"bray_curtis_pcoa_results\" )
    for i in \"\${method[@]}\"
    do
	qiime emperor plot \
                --i-pcoa $core/\$i.qza \
                --m-metadata-file ${params.metadata} \
                --o-visualization $core/\$i.qzv \
                --verbose
	qiime tools export $core/\$i.qzv \
                --output-dir ${params.outdir}/beta-diversity/\$i-PCoA
    done
    """
}


/*
 * Differential abundance analysis with ANCOM
 */
process ancom { 
    echo true

    input:
    val table from qiime_table
    val taxonomy from qiime_taxonomy
    val meta from meta_category_all

    when:
    !params.skip_ancom


    """
    IFS=',' read -r -a metacategory <<< \"$meta\"
    echo perform ancom on "\${metacategory[@]}\"

    #remove samples that do not have any value
    for j in \"\${metacategory[@]}\"
    do
	qiime feature-table filter-samples \
		--i-table $table \
		--m-metadata-file ${params.metadata} \
		--p-where \"\$j<>\'\'\" \
		--o-filtered-table ancom/\$j-table.qza
    done

    # ANCOM on reduced tax level
    array=( 2 3 4 5 6 )
    for i in \"\${array[@]}\"
    do
	for j in \"\${metacategory[@]}\"
	do
		qiime taxa collapse \
		        --i-table ancom/\$j-table.qza \
		        --i-taxonomy $taxonomy \
		        --p-level \"\$i\" \
		        --o-collapsed-table ancom/\$j-l\$i-table.qza \
		        --verbose
		qiime composition add-pseudocount \
		        --i-table ancom/\$j-l\$i-table.qza \
		        --o-composition-table ancom/\$j-l\$i-comp-table.qza
		qiime composition ancom \
		        --i-table ancom/\$j-l\$i-comp-table.qza \
		        --m-metadata-file ${params.metadata} \
		        --m-metadata-column \"\$j\" \
		        --o-visualization ancom/\$j-l\$i-comp-table.qzv \
		        --verbose
		qiime tools export ancom/\$j-l\$i-comp-table.qzv \
		        --output-dir ${params.outdir}/ancom/Category-\$j-level-\$i
	done
    done

    # ANCOM on ASV level
    for j in \"\${metacategory[@]}\"
    do
    qiime composition add-pseudocount \
		--i-table ancom/\$j-table.qza \
		--o-composition-table ancom/\$j-comp-table.qza
	qiime composition ancom \
	        --i-table ancom/\$j-comp-table.qza \
	        --m-metadata-file ${params.metadata} \
	        --m-metadata-column \"\$j\" \
	        --o-visualization ancom/\$j-comp-table.qzv \
	        --verbose
	qiime tools export ancom/\$j-comp-table.qzv \
	        --output-dir ${params.outdir}/ancom/Category-\$j-ASV
    done
    """
}

/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    tag "$prefix"
    publishDir "${params.outdir}/Documentation", mode: 'copy'

    input:
    file output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}



/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/rrna-ampliseq] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/rrna-ampliseq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = manifest.pipelineVersion
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir" ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/rrna-ampliseq] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/rrna-ampliseq] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/Documentation/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    log.info "[nf-core/rrna-ampliseq] Pipeline Complete"

}