
###############################################################################
 #
 #  This file is part of canu, a software program that assembles whole-genome
 #  sequencing reads into contigs.
 #
 #  This software is based on:
 #    'Celera Assembler' (http://wgs-assembler.sourceforge.net)
 #    the 'kmer package' (http://kmer.sourceforge.net)
 #  both originally distributed by Applera Corporation under the GNU General
 #  Public License, version 2.
 #
 #  Canu branched from Celera Assembler at its revision 4587.
 #  Canu branched from the kmer project at its revision 1994.
 #
 #  Modifications by:
 #
 #    Brian P. Walenz beginning on 2018-APR-23
 #      are a 'United States Government Work', and
 #      are released in the public domain
 #
 #  File 'README.licenses' in the root directory of this distribution contains
 #  full conditions and disclaimers for each license.
 ##

package canu::SequenceStore;

require Exporter;

@ISA    = qw(Exporter);
@EXPORT = qw(getNumberOfReadsInStore
             getNumberOfBasesInStore
             getSizeOfSequenceStore
             getExpectedCoverage
             generateReadLengthHistogram
             checkSequenceStore);

use strict;
use warnings "all";
no  warnings "uninitialized";

use Cwd qw(getcwd);

use canu::Defaults;
use canu::Execution;

use canu::Report;
use canu::Output;

use canu::Grid_Cloud;


use Carp qw(longmess cluck confess);


sub getNumberOfReadsInStore ($$) {
    my $asm    = shift @_;
    my $tag    = shift @_;
    my $nr     = 0;

    confess  if (($tag ne "all") && ($tag ne "hap") && ($tag ne "cor") && ($tag ne "obt") && ($tag ne "utg"));

    #  No file, no reads.

    return($nr)   if (! -e "./$asm.seqStore/info.txt");

    #  Read the info file.  sqStoreCreate creates this at the end.
    #
    #  The 'all' category returns the number of reads that are in the store; essentailly, the maxID of any read.
    #  The 'cor' category returns the number of reads that are available for correction.
    #  The 'obt' category returns the number of reads that are available for trimming.
    #  The 'utg' category returns the number of reads that are available for assembly.

    open(F, "< ./$asm.seqStore/info.txt") or caExit("can't open './$asm.seqStore/info.txt' for reading: $!", undef);
    while (<F>) {
        if (m/^\s*(\d+)\s+([0123456789-]+)\s+(.*)\s*$/) {
            $nr = $1 if (($3 eq "total-reads")       && ($tag eq "all"));
            $nr = $1 if (($3 eq "raw")               && ($tag eq "cor"));
            $nr = $1 if (($3 eq "raw")               && ($tag eq "hap"));
            $nr = $1 if (($3 eq "corrected")         && ($tag eq "obt"));
            $nr = $1 if (($3 eq "corrected-trimmed") && ($tag eq "utg"));
        }
    }
    close(F);

    #print STDERR "-- Found $nr reads in '$asm.seqStore', for tag '$tag'\n";

    return($nr);
}



sub getNumberOfBasesInStore ($$) {
    my $asm    = shift @_;
    my $tag    = shift @_;
    my $nb     = 0;

    confess  if (($tag ne "hap") && ($tag ne "cor") && ($tag ne "obt") && ($tag ne "utg"));

    #  No file, no bases.

    return($nb)   if (! -e "./$asm.seqStore/info.txt");

    #  Read the info file.  sqStoreCreate creates this at the end.

    open(F, "< ./$asm.seqStore/info.txt") or caExit("can't open './$asm.seqStore/info.txt' for reading: $!", undef);
    while (<F>) {
        if (m/^\s*(\d+)\s+(\d+)\s+(.*)\s*$/) {
            $nb = $2 if (($3 eq "raw")               && ($tag eq "cor"));
            $nb = $2 if (($3 eq "raw")               && ($tag eq "hap"));
            $nb = $2 if (($3 eq "corrected")         && ($tag eq "obt"));
            $nb = $2 if (($3 eq "corrected-trimmed") && ($tag eq "utg"));
        }
    }
    close(F);

    return($nb);
}



sub getSizeOfSequenceStore ($) {
    my $asm    = shift @_;
    my $size   = 0;
    my $idx    = "0000";

    $size += -s "./$asm.seqStore/info";
    $size += -s "./$asm.seqStore/libraries";
    $size += -s "./$asm.seqStore/reads";

    while (-e "./$asm.seqStore/blobs.$idx") {
        $size += -s "./$asm.seqStore/blobs.$idx";
        $idx++;
    }

    return(int($size / 1024 / 1024 / 1024 + 1.5));
}



sub getExpectedCoverage ($$) {
    my $tag    = shift @_;
    my $asm    = shift @_;

    return(int(getNumberOfBasesInStore($asm, $tag) / getGlobal("genomeSize")));
}



sub createSequenceStore ($$@) {
    my $base   = shift @_;
    my $asm    = shift @_;
    my $bin    = getBinDirectory();
    my @inputs = @_;

    #  Fail if there are no inputs.

    caExit("no input files specified, and store not already created, I have nothing to work on!", undef)
        if (scalar(@inputs) == 0);


    #  Fetch the reads from the object store.
    #  A similar blcok is used in SequenceStore.pm and HaplotypeReads.pm (twice).

    #if (defined(getGlobal("objectStore"))) {
    #    for (my $ff=0; $ff < scalar(@inputs); $ff++) {
    #        my ($inType, $inPath, $otPath) = split '\0', $inputs[$ff];
    #
    #        $otPath =  $inPath;
    #        $otPath =~ s!/!_!;
    #
    #        fetchObjectStoreFile($inPath, $otPath);
    #
    #        $inputs[$ff] = "$inType\0$otPath";
    #
    #        print STDERR "$inType -- '$inPath' -> '$otPath'\n";
    #    }
    #}


    if (! -e "./$asm.seqStore.sh") {
        open(F, "> ./$asm.seqStore.sh") or caExit("cant' open './$asm.seqStore.sh' for writing: $0", undef);

        print F "#!" . getGlobal("shell") . "\n";
        print F "\n";
        print F getBinDirectoryShellCode();
        print F "\n";
        print F setWorkDirectoryShellCode(".");
        print F "\n";

        print F "\n";
        print F "$bin/sqStoreCreate \\\n";
        print F "  -o ./$asm.seqStore.BUILDING \\\n";
        print F "  -minlength "  . getGlobal("minReadLength")        . " \\\n";

        if (getGlobal("readSamplingCoverage") > 0) {
            print F "  -genomesize " . getGlobal("genomeSize")           . " \\\n";
            print F "  -coverage   " . getGlobal("readSamplingCoverage") . " \\\n";
            print F "  -bias       " . getGlobal("readSamplingBias")     . " \\\n";
        }

        foreach my $iii (@inputs) {
            if ($iii =~ m/^(.*)\0(.*)$/) {
                my $tech = $1;
                my $file = $2;
                my @name = split '/', $2;
                my $name = $name[scalar(@name)-1];

                $name = $1   if ($name =~ m/(.*).[xgb][z]2{0,1}$/i);
                $name = $1   if ($name =~ m/(.*).fast[aq]$/i);
                $name = $1   if ($name =~ m/(.*).f[aq]$/i);

                print F "  $tech $name $file \\\n";

            } else {
                caExit("unrecognized sqStoreCreate input file '$iii'", undef);
            }
        }

        print F "&& \\\n";
        print F "mv ./$asm.seqStore.BUILDING ./$asm.seqStore \\\n";
        print F "&& \\\n";
        print F "exit 0\n";
        print F "\n";
        print F "exit 1\n";

        close(F);

        makeExecutable("./$asm.seqStore.sh");
        stashFile("./$asm.seqStore.sh");
    }

    #  Load the store.

    if (runCommand(".", "./$asm.seqStore.sh > ./$asm.seqStore.err 2>&1") > 0) {
        caExit("sqStoreCreate failed; boom!", "./$asm.seqStore.err");
    }

    if (! -e "./$asm.seqStore/info.txt") {
        caExit("sqStoreCreate failed; no info file", "./$asm.seqStore.err");
    }
}



sub generateReadLengthHistogram ($$) {
    my $tag    = shift @_;
    my $asm    = shift @_;
    my $bin    = getBinDirectory();

    my $reads    = getNumberOfReadsInStore($asm, $tag);
    my $bases    = getNumberOfBasesInStore($asm, $tag);
    my $coverage = int(100 * $bases / getGlobal("genomeSize")) / 100;
    my $hist;

    my @rl;
    my @hi;

    #  Generate a lovely PNG histogram.

    if (! -e "./$asm.seqStore/readlengths-$tag.dat") {
        my $cmd;

        $cmd  = "$bin/sqStoreDumpMetaData \\\n";
        $cmd .= "  -S ./$asm.seqStore \\\n";
        $cmd .= "  -raw \\\n"                  if ($tag eq "cor");
        $cmd .= "  -corrected \\\n"            if ($tag eq "obt");
        $cmd .= "  -corrected -trimmed \\\n"   if ($tag eq "utg");
        $cmd .= "  -histogram " . getGlobal("genomeSize") . " \\\n";
        $cmd .= "  -lengths \\\n";
        $cmd .= "> ./$asm.seqStore/readlengths-$tag.dat \\\n";
        $cmd .= "2> ./$asm.seqStore/readlengths-$tag.err \n";

        if (runCommand(".", $cmd) > 0) {
            caExit("sqStoreDumpMetaData failed", "./$asm.seqStore/readlengths-$tag.err");
        }

        unlink "./$asm.seqStore/readlengths-$tag.err";

        my $gnuplot = getGlobal("gnuplot");
        my $format  = getGlobal("gnuplotImageFormat");

        if ($gnuplot) {
            open(F, "> ./$asm.seqStore/readlengths-$tag.gp") or caExit("can't open './$asm.seqStore/readlengths-$tag.gp' for writing: $!", undef);
            print F "set title 'read length'\n";
            print F "set xlabel 'read length, bin width = 250'\n";
            print F "set ylabel 'number of reads'\n";
            print F "\n";
            print F "binwidth=250\n";
            print F "set boxwidth binwidth\n";
            print F "bin(x,width) = width*floor(x/width) + binwidth/2.0\n";
            print F "\n";
            print F "set terminal $format size 1024,1024\n";
            print F "set output './$asm.seqStore/readlengths-$tag.$format'\n";
            print F "plot [] './$asm.seqStore/readlengths-$tag.dat' using (bin(\$1,binwidth)):(1.0) smooth freq with boxes title ''\n";
            close(F);

            if (runCommandSilently(".", "$gnuplot < /dev/null ./$asm.seqStore/readlengths-$tag.gp > /dev/null 2>&1", 0)) {
                print STDERR "--\n";
                print STDERR "-- WARNING: gnuplot failed.\n";
                print STDERR "--\n";
                print STDERR "----------------------------------------\n";
            }
        }
    }

    #  Generate a lovely ASCII histogram.

    if (! -e "./$asm.seqStore/readlengths-$tag.txt") {
        my $cmd;

        $cmd  = "$bin/sqStoreDumpMetaData \\\n";
        $cmd .= "  -S ./$asm.seqStore \\\n";
        $cmd .= "  -raw \\\n"                  if ($tag eq "cor");
        $cmd .= "  -corrected \\\n"            if ($tag eq "obt");
        $cmd .= "  -corrected -trimmed \\\n"   if ($tag eq "utg");
        $cmd .= "  -histogram " . getGlobal("genomeSize") . " \\\n";
        $cmd .= "> ./$asm.seqStore/readlengths-$tag.txt \\\n";
        $cmd .= "2> ./$asm.seqStore/readlengths-$tag.err \n";

        if (runCommand(".", $cmd) > 0) {
            caExit("sqStoreDumpMetaData failed", "./$asm.seqStore/readlengths-$tag.err");
        }

        unlink "./$asm.seqStore/readlengths-$tag.err";
    }

    #  Read the ASCII histogram, append to report.

    $hist  = "--\n";
    $hist .= "-- In sequence store './$asm.seqStore':\n";
    $hist .= "--   Found $reads reads.\n";
    $hist .= "--   Found $bases bases ($coverage times coverage).\n";

    if (-e "./$asm.seqStore/readlengths-$tag.txt") {
        #$hist .= "--\n";
        #$hist .= "--   Read length histogram (one '*' equals " . int(100 * $scale) / 100 . " reads):\n";

        open(F, "< ./$asm.seqStore/readlengths-$tag.txt") or caExit("can't open './$asm.seqStore/readlengths-$tag.txt' for reading: $!", undef);
        while (<F>) {
            $hist .= "--    $_";
        }
        close(F);
    }

    #  Abort if the read coverage is too low.

    my $minCov = getGlobal("stopOnLowCoverage");

    if ($coverage < $minCov) {
        print STDERR "--\n";
        print STDERR "-- ERROR:  Read coverage ($coverage) is too low to be useful.\n";
        print STDERR "-- ERROR:\n";
        print STDERR "-- ERROR:  This could be caused by an incorrect genomeSize or poor quality reads that could not\n";
        print STDERR "-- ERROR:  be sufficiently corrected.\n";
        print STDERR "-- ERROR:\n";
        print STDERR "-- ERROR:  You can force Canu to continue by decreasing parameter stopOnLowCoverage=$minCov,\n";
        print STDERR "-- ERROR:  however, the quality of corrected reads and/or contiguity of contigs will be poor.\n";
        print STDERR "-- \n";

        caExit("", undef);
    }

    #  Return the ASCII histogram.

    return($hist);
}



sub checkSequenceStore ($$@) {
    my $base;
    my $asm    = shift @_;
    my $tag    = shift @_;
    my $bin    = getBinDirectory();
    my @inputs = @_;

    $base = "haplotype"   if ($tag eq "hap");
    $base = "correction"  if ($tag eq "cor");
    $base = "trimming"    if ($tag eq "obt");
    $base = "unitigging"  if ($tag eq "utg");

    #  Try fetching the store from object storage.  This might not be needed in all cases (e.g.,
    #  between mhap precompute and mhap compute), but it greatly simplifies stuff, like immediately
    #  here needing to check if the store exists.

    fetchSeqStore($asm);

    #  We cannot abort this step anymore.  If trimming is skipped, we need ro promote the corrected
    #  reads to trimmed reads, and also re-stash the store.
    #
    #goto allDone    if (getNumberOfReadsInStore($asm, $tag) > 0);

    #  Create the store.

    my $histAndStash = 0;

    if (! -e "./$asm.seqStore") {
        createSequenceStore($base, $asm, @inputs);

        $histAndStash = 1;
    }

    #  Dump the list of libraries.  Various parts use this for various stuff.

    if (! -e "./$asm.seqStore/info.txt") {
        if (runCommandSilently(".", "$bin/sqStoreDumpMetaData -S ./$asm.seqStore -stats > ./$asm.seqStore/info.txt 2> /dev/null", 1)) {
            caExit("failed to generate $asm.seqStore/info.txt", undef);
        }
    }

    if (! -e "./$asm.seqStore/libraries.txt") {
        if (runCommandSilently(".", "$bin/sqStoreDumpMetaData -S ./$asm.seqStore -libs > ./$asm.seqStore/libraries.txt 2> /dev/null", 1)) {
            caExit("failed to generate $asm.seqStore/libraries.txt", undef);
        }
    }

    #  Query how many reads we have.

    my $nCor = getNumberOfReadsInStore($asm, "cor");   #  Number of corrected reads ready for OBT.
    my $nOBT = getNumberOfReadsInStore($asm, "obt");   #  Number of corrected reads ready for OBT.
    my $nAsm = getNumberOfReadsInStore($asm, "utg");   #  Number of trimmed reads ready for assembly.

    #  Refuse to assemble uncorrected reads.

    if (($tag eq "utg") &&    #  Assembling.
        ($nCor >  0) &&       #  And raw reads exist.
        ($nOBT == 0) &&       #  But no corrected reads.
        ($nAsm == 0)) {       #  And no trimmed reads!

        print STDERR "-- Unable to assemble uncorrected reads.\n";

        caExit("unable to assemble uncorrected reads", undef);
    }

    #  Set or unset the homopolymer compression flag.

    if (defined(getGlobal("homoPolyCompress"))) {
        touch("./$asm.seqStore/homopolymerCompression");
    } else {
        unlink("./$asm.seqStore/homopolymerCompression");
    }

    #  Make a histogram and stash the (updated) store.

    if ($histAndStash) {
        addToReport("${tag}SeqStore", generateReadLengthHistogram($tag, $asm));
        stashSeqStore($asm);
    }

    #  Refuse to conitnue if there are no reads.

    if ((($tag eq "cor") && ($nCor == 0)) ||
        (($tag eq "obt") && ($nOBT == 0)) ||
        (($tag eq "utg") && ($nAsm == 0))) {

        print STDERR "--\n";
        print STDERR "-- WARNING:\n";
        print STDERR "-- WARNING:  No raw ",       "reads detected.  Cannot proceed; empty outputs generated.\n"  if ($tag eq "cor");
        print STDERR "-- WARNING:  No corrected ", "reads detected.  Cannot proceed; empty outputs generated.\n"  if ($tag eq "obt");
        print STDERR "-- WARNING:  No trimmed ",   "reads detected.  Cannot proceed; empty outputs generated.\n"  if ($tag eq "utg");
        print STDERR "-- WARNING:\n";
        print STDERR "--\n";

        generateOutputs($asm);

        return(0);
    }

  finishStage:
    generateReport($asm);

    #  DO NOT resetIteration() here.  This function runs to completion on every
    #  restart, so resetting would obliterate the iteration count.
    #resetIteration("$tag-sqStoreCreate");

  allDone:
    stopAfter("sequenceStore");

    return(1);
}
