package FuturePostJob::Callbacks;
use strict;

use MT::Util qw ( ts2epoch );

sub entry_post_save {
	my ($cb, $entry, $entry_orig) = @_;
	return if $entry->{fpj_created};
	my $entry_id = $entry->id;
	my $plugin = MT->component('FuturePostJob');
	my $config = $plugin->get_config_hash('blog:'.$entry->blog_id);
	# config directive enables for all blogs even if blog-level setting not enabled.
	my $enabled = $config->{enable_job} || MT->config('UseJobForFuturePosts');
	return if !$enabled;
	
	require MT::Entry;
	if ($entry->status == MT::Entry::FUTURE()) {
	    require MT::TheSchwartz;
	    my $key = 'futurepost_' . $entry->id;
	    # to schedule the job for the correct time, authored_on must be converted to system time first
        my $authored_on = $entry->authored_on;
        # the following catches a case where the callback is run before the entry's authored_on is set correctly in ts format
        if ( $authored_on =~
            m!(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})(?::(\d{2}))?! ) {
			my $s = $6 || 0;
			$authored_on = sprintf "%04d%02d%02d%02d%02d%02d", $1, $2, $3, $4, $5, $s;
		}
		my $pub_date = ts2epoch($entry->blog, $authored_on);
		require MT::TheSchwartz::Job;
	    my $job = MT::TheSchwartz::Job->load({ uniqkey => $key });
	    my $replace;
	    if ($job) {
	        # job already exists but we should confirme the run_after date still matches authored_on
	        if ($authored_on != $job->run_after) {
	            # future date has changed, remove job and add a new one
	            $job->remove;
	        }
	    }
	    
    	$job = TheSchwartz::Job->new();
        $job->funcname('FuturePostJob::Worker::Publish');
        $job->uniqkey($key);
        my $priority = 10;
        $job->priority($priority);
    	$job->run_after($pub_date);
        MT::TheSchwartz->insert($job);
        $entry->{fpj_created} = 1;
	}
	return 1;
}

1;