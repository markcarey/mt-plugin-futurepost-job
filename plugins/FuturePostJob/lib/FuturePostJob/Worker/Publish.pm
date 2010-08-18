package FuturePostJob::Worker::Publish;

use strict;
use base qw( TheSchwartz::Worker );

use MT::Util qw( offset_time_list );

use TheSchwartz::Job;

sub work {
    my $class                = shift;
    my TheSchwartz::Job $job = shift;
    my $key = $job->uniqkey;
    
    eval {
        publish_future_post($key);
    };
	if ( $@ ) {
        $job->failed( qq{FuturePostJob::Worker::Publish error: } .
                $job->uniqkey . ': ' . $@ );
    } else {
        $job->completed();
    }
}

sub grab_for    {120}
sub max_retries {10}
sub retry_delay {60}


sub publish_future_post {
    my ($key) = @_;
    my $mt = MT->instance;
    require MT::Entry;

    if ($key =~ /^futurepost_([0-9]+)$/) {
        my $entry_id = $1;
        my $entry = MT->model('entry')->load($entry_id);
        return unless $entry;
        
        # now double check the status and authored_on date to make sure it is okay to publish
        return unless ($entry->status == MT::Entry::FUTURE());
        my $blog = $entry->blog;
        my @ts = offset_time_list( time, $blog );
        my $now = sprintf "%04d%02d%02d%02d%02d%02d", $ts[5] + 1900, $ts[4] + 1,
          @ts[ 3, 2, 1, 0 ];
        if ($entry->authored_on le $now) {
            # status is Scheduled and date is in the past, okay to publish
            # most of this is from MT::WeblogPublisher::publish_future_posts
            my %rebuild_queue;
            my %ping_queue;
            $entry->status( MT::Entry::RELEASE() );
            $entry->save
              or die $entry->errstr;

            MT->run_callbacks( 'scheduled_post_published', $mt, $entry );

            $rebuild_queue{ $entry->id } = $entry;
            $ping_queue{ $entry->id }    = 1;
            my $n = $entry->next(1);
            $rebuild_queue{ $n->id } = $n if $n;
            my $p = $entry->previous(1);
            $rebuild_queue{ $p->id } = $p if $p;
            
            eval {
                foreach my $id ( keys %rebuild_queue )
                {
                    my $e = $rebuild_queue{$id};
                    $mt->rebuild_entry( Entry => $e, Blog => $blog )
                      or die $mt->errstr;
                    if ( $ping_queue{$id} ) {
                        $mt->ping_and_save( Entry => $e, Blog => $blog );
                    }
                }
                $mt->rebuild_indexes( Blog => $blog )
                  or die $mt->errstr;
            };
            if ( my $err = $@ ) {
                # a fatal error occured while processing the rebuild
                # step. LOG the error and revert the entry/entries:
                require MT::Log;
                $mt->log(
                    {
                        message => $mt->translate(
"An error occurred while publishing scheduled entries via job: [_1]",
                            $err
                        ),
                        class   => "system",
                        blog_id => $blog->id,
                        level   => MT::Log::ERROR()
                    }
                );
                $entry->status( MT::Entry::FUTURE() );
                $entry->save or die $entry->errstr;
            }
        } else {
            # date is still in future, maybe date was changed. save it to trigger job creation callback
            $entry->save or die $entry->errstr;
        }
    }
}

1;