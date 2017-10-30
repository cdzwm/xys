use utf8;
package Type1;
use Modern::Perl;
use Encode qw(decode encode);
use Log::Log4perl qw(get_logger);
use lib '../lib';

use Moose;
extends 'Type';

my $log = Log::Log4perl->get_logger('Type1');

sub reformat_para{
	my $para=shift;
	my @lines= split /\n/, $para;
	chomp @lines;
	$para = join("\n", @lines);
	my @l=split /\n\s+/, $para;
	for (@l){
		s/\n+//g;
		s/^[\s\n]+//;
		s/^◆\s*//;
	}

	return join("\n", @l);
}

sub reformat_poe_para{
	my $para=shift;
	my @lines= split /\n/, $para;
	chomp @lines;
	$para = join("\n", @lines);
	my @l=split /\n\s+/, $para;
	for (@l){
		s/^[\s\n]+//;
	}

	return join("\n", @l);
}

sub reformat_article{
	my $title=shift;
	my $data=shift;
	my @p1 = split /\n\n/, $data;

	my @paras;
	for(@p1){
		push @paras, reformat_para($_);
	}

	s/^\n// for @paras;
	return { title=>$title, content=>join("\n", map {$_} @paras)};
}

sub reformat_poe{
	my $data=shift;
	$data =~ s/^\s*//;
	my @p1 = split /\n\n/, $data;

	my @paras;
	for(@p1){
		push @paras, reformat_poe_para($_);
	}

	s/^\n// for @paras;
	return { title=>'卷首诗： ' . $paras[0], content=>join("\n", map {$_} @paras)};
}
sub recognize{
	my (undef, $file_data) =@_;

	# determine file format
	my $issn_str = '国际刊号：ＩＳＳＮ　１０８１－９２０７';
	my $issn_q = quotemeta $issn_str;
	my $issn_re = qr/^\s*$issn_q\s*$/m;
	unless( $file_data =~ $issn_re ){
		return;
	}

	# split into parts
	my $sep1=qr/^※+\s*?$/m;

	my @parts = split $sep1, $file_data;
	my ($toc, $cover, $body, $foot) = splice @parts, 0, 4;
	unless($toc && $cover && $body && $foot){
		$log->debug('File format error.');
		return;
	}

	my $r={};
	my $update_date;
	eval{
		# get update date
		if( my (@ymd) = $toc =~ /^\s*新语丝新到资料（(\d{4})年(\d{1,2})月(\d{1,2})日）\s*$/m ){
			$update_date = sprintf '%04d%02d%02d', @ymd;
		}
	
		$r->{issue}=$update_date;
	};
	if($@){
		$log->error("$@");
	}

	# get preface & articles
	my $article_sep = qr/^\s*【(.*?)】∽+?$/m;
	my @articles=split $article_sep, $body;

	# preface
	my $preface = shift @articles;

	$r->{articles}=[];

	# poe
	my $poe_re = qr/^.*?§/m;
	$preface =~ s/$poe_re//g;

	my @lines = split /\n/, $preface;
	s/^[\s　]*|[\s　]*$//m for @lines;
	my $poe_text = join "\n", @lines;

	my $seqid=0;

	# TODO: poe
	my $poe=&reformat_poe($poe_text);
	unless($update_date){
		my ($poe_update_date) = $file_data =~ /\(XYS(\d{4}\d{2}\d{2})\)$/mi;
		say STDERR $poe_update_date;
		$poe->{date} = $poe_update_date;
	}
	else{
		$poe->{date} = $update_date;
	}

	$poe->{seqid}=$seqid++;
	push @{ $r->{articles} }, $poe;

	# articles
	while(my ($title, $content) = splice @articles, 0, 2){
		my $article=&reformat_article($title, $content);

		unless($update_date){
			#(XYS20050912)
			my ($article_update_date) = $_ =~ /^\(XYS(\d{4}\d{2}\d{2})\)$/mi;
			$article->{date} = $article_update_date;
		}
		else{
			$article->{date} = $update_date;
		}

		$article->{seqid}=$seqid++;
		push @{ $r->{articles} }, $article; 
	}
	$r;
}

1;
