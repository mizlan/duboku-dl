use Getopt::ArgParse;
use HTTP::Request;
use LWP::UserAgent;
use Mojo::DOM;
use File::Path qw(make_path);
use strict;
use warnings;
use v5.32;
use feature 'say';

#### How this works:
# 1. Provide the summary URL (this should have buttons to
#    each episode of the season at the bottom)
# 2. Dubroku will open each episode and extract the video
#    information by parsing the HTML
# 3. For each episode, Dubroku will download the small .ts
#    files, and then shell out to ffmpeg to remux the .ts
#    into an mp4.

my $ap = Getopt::ArgParse->new_parser(
  prog        => 'Dubroku',
  description => 'Download Duboku episodes',
  epilog      => 'made by @mizlan',
);

$ap->add_arg(
  '--episodes',
  '--episode',
  '-e',
  required => 1,
  help => 'The selection of episodes to download. Either a single number, a range (e.g. 4-6) or comma-separated (e.g. 3,5,6)'
);
$ap->add_arg('url', required => 1, help => 'Duboku url of season summary. e.g., https://tv.gboku.com/voddetail/2836.html');
$ap->add_arg('--output-directory', '--dir', '-o', required => 1, help => 'directory in which to place downloaded videos');
$ap->add_arg('--debug', '-g', type => 'Bool', help => 'print more information than normal');
$ap->add_arg('--quiet', '-q', type => 'Bool', help => 'print no information');

my $ns = $ap->parse_args();
my $DEBUG = $ns->debug;
my $QUIET = $ns->quiet;

my $directory = $ns->output_directory;

# check if URL is valid
my ($summary_url, $summary_id);
if ($ns->url !~ m{voddetail/(\d+)}) {
  die "url format not valid, should be like https://tv.gboku.com/voddetail/2836.html";
} else {
  $summary_url = $ns->url;
  $DEBUG and say "url: $summary_url";
  $summary_id = $1;
}

# "deserialize" episode numbers into array
my @episodes;
if ($ns->episodes =~ /(\d+)-(\d+)/) {
  @episodes = ( $1 .. $2 );
} elsif ($ns->episodes =~ /\d+(,\d+)*/) {
  @episodes = $ns->episodes =~ /\d+/g;
} 

$DEBUG and say "episodes: ", join(", ", @episodes);

# for some reason, curl UA is allowed... let's use it
# because the perl default UA returns 403
my $ua = LWP::UserAgent->new(agent => 'curl/7.37.0');

# pull list of episode links
my $request = HTTP::Request->new(GET => $summary_url);
my $response = $ua->request($request);

$response->is_error and die $response->status_line;

my $dom = Mojo::DOM->new($response->decoded_content);
my $links = $dom->find('#playlist1 a')->map(attr => 'href');
$DEBUG and say "found:\n", $links->join("\n");

my @episode_links;
$summary_url =~ m{(.*)/voddetail};
my $url_head = $1;
$DEBUG and say "url head $url_head";

for my $link (@$links) {
  $link =~ m{vodplay/$summary_id-1-(\d+)};
  my $episode_number = $1;
  if (grep /^$episode_number$/, @episodes) {
    push @episode_links, "$url_head$link";
  }
}

$DEBUG and say join("\n", @episode_links);

for my $episode_link (@episode_links) {
  $episode_link =~ m{vodplay/$summary_id-1-(\d+)};
  my $episode_number = $1;

  my $request = HTTP::Request->new(GET => $episode_link);
  my $response = $ua->request($request);

  $response->is_error and die $response->status_line;

  my $dom = Mojo::DOM->new($response->decoded_content);
  my $str = $dom->find('script')->grep(sub { $_->text =~ /m3u8/ })->first;
  $DEBUG and say $str;
  $str =~ /"url":\s*"(\S+?)"/;
  my $m3u8_url = $1;
  $m3u8_url =~ s{\\/}{/}g;

  $m3u8_url =~ m{^(\w+://)?[^/]+};

  my $m3u8_host = $1;
  $DEBUG and say $m3u8_host;

  # duboku's true m3u8 url is just this url with
  # an additional hls/ component within, e.g.
  # from .../20220527/2NAs8HDW/index.m3u8
  # to   .../20220527/2NAs8HDW/hls/index.m3u8
  $m3u8_url =~ s{index}{hls/index};

  $QUIET or say "downloading episode $episode_number";
  $QUIET or say "m3u8 URL: $m3u8_url";

  # retrieve all the .ts pieces
  $request = HTTP::Request->new(GET => $m3u8_url);
  $response = $ua->request($request);

  $response->is_error and die $response->status_line;

  my $m3u8_file = $response->decoded_content;

  $DEBUG and say $m3u8_file;

  if ($m3u8_file =~ /#EXT-X-KEY/) {
    die 'this is encrypted (unexpected). contact michaellan202@gmail.com';
  }

  make_path($directory);
  my $episode_ts_filename = "$directory/ep$episode_number.ts";
  open(my $episode_ts_fh, '>:raw', $episode_ts_filename) or die "cannot create .ts file";
  # for each chunk, download and append. then use ffmpeg to convert
  my @chunks = $m3u8_file =~ /^[^#].*\.ts$/mg;
  my $num_chunks = @chunks;
  for my $chunk_idx (0 .. $#chunks) {
    my $chunk_url = $chunks[$chunk_idx];

    my $request = HTTP::Request->new(
      GET => $chunk_url,
      [ referer => "$m3u8_host/static/player/videojs.html" ]
    );
    my $response = $ua->request($request);

    $response->is_error and die $response->status_line;

    print $episode_ts_fh $response->content;

    $QUIET or printf "\ron chunk %*d/%d", length($num_chunks), $chunk_idx + 1, $num_chunks and STDOUT->flush();
  }
  $QUIET or print "\n";
  close($episode_ts_fh);

  # convert .ts to .mp4 without re-encoding
  system(qw(ffmpeg -y -i), $episode_ts_filename, qw(-c copy), "$directory/ep$episode_number.mp4");
}
