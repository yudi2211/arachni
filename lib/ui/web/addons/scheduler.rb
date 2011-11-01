=begin
                  Arachni
  Copyright (c) 2010-2011 Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>

  This is free software; you can copy and distribute and modify
  this program under the term of the GPL v2.0 License
  (See LICENSE file for details)

=end

module Arachni
module UI
module Web
module Addons

#
#
# Scheduler add-on.
#
# @author: Tasos "Zapotek" Laskos
#                                      <tasos.laskos@gmail.com>
#                                      <zapotek@segfault.gr>
#
# @version: 0.1.1
#
class Scheduler < Base

    def run

        aget "/" do
            prep_session
            settings.dispatchers.stats {
                |stats|
                async_present :index,
                    :jobs => scheduler.jobs( :order => :created_at.desc ),
                    :root => current_addon.path_root,
                    :d_stats => stats
            }
        end

        post '/' do
            valid = true

            prep_session
            begin
                URI.parse( params['url'] )
            rescue
                valid = false
            end

            if !params['url'] || params['url'].empty? || !valid
                flash[:err] = "Invalid URL."
            elsif !params['dispatcher'] || params['dispatcher'].empty?
                flash[:err] = "Please select a Dispatcher."
            else

                session['opts']['settings']['url'] = params[:url]

                unescape_hash( session['opts'] )
                session['opts']['settings']['audit_links']   = true if session['opts']['settings']['audit_links']
                session['opts']['settings']['audit_forms']   = true if session['opts']['settings']['audit_forms']
                session['opts']['settings']['audit_cookies'] = true if session['opts']['settings']['audit_cookies']
                session['opts']['settings']['audit_headers'] = true if session['opts']['settings']['audit_headers']

                opts = {}
                # opts['settings'] = prep_opts( session['opts']['settings'] )
                opts['settings'] = session['opts']['settings']
                opts['plugins']  = YAML::load( session['opts']['plugins'] )
                opts['modules']  = session['opts']['modules']

                if params[:datetime] && !params[:datetime].empty?

                    job = Arachni::UI::Web::Scheduler::Job.new(
                        :dispatcher  => params[:dispatcher],
                        :url         => params[:url],
                        :opts        => opts.to_yaml,
                        :owner_addr  => env['REMOTE_ADDR'],
                        :owner_host  => env['REMOTE_HOST'],
                        :created_at  => Time.now
                    )

                    begin
                        job.datetime = parse_datetime( params[:datetime] )

                        if !job.valid?
                            msg = [ :err, 'Job holds invalid data, skipping...' ]
                        else
                            job.save
                            msg = [ :ok, "Job saved." ]
                        end
                    rescue Exception => e
                        msg = [ :err, 'Could not parse date (' + e.to_s + ').' ]
                    end

                else
                    msg = [ :err, 'Date cannot be empty.' ]
                end
            end

            redirect  '/', :flash => { msg[0] => msg[1] }
        end

        post '/delete' do
            scheduler.delete_all
            log.scheduler_jobs_deleted( env )

            redirect  '/'
        end

        post '/:id/delete' do
            scheduler.delete( params[:id] )
            log.scheduler_job_deleted( env, params[:id] )

            redirect '/'
        end

    end

    def title
        "Scheduler [#{settings.scheduler.jobs.size}]"
    end

    def self.info
        {
            :name           => 'Scheduler',
            :description    => %q{Schedules and runs scan jobs.},
            :author         => 'Tasos "Zapotek" Laskos <tasos.laskos@gmail.com> ',
            :version        => '0.1.1'
        }
    end


end

end
end
end
end
