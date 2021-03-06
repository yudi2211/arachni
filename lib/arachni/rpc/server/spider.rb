=begin
    Copyright 2010-2013 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

module Arachni

module RPC
class Server

#
#
# Extends the regular {Arachni::Spider} with high-performance distributed capabilities.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Spider < Arachni::Spider

    # Amount of URLs to buffer before distributing.
    BUFFER_SIZE     = 200

    # How many times to try and fill the buffer before distributing what's in it.
    FILLUP_ATTEMPTS = 30

    private :push, :done?, :sitemap, :running?
    public  :push, :done?, :sitemap, :running?

    def initialize( framework )
        super( framework.opts )

        @framework    = framework
        @peers        = {}
        @done_signals = Hash.new( true )

        @distribution_filter   = BloomFilter.new

        @after_each_run_blocks = []
        @on_first_run_blocks   = []
    end

    # @param    [Block] block   Block to be called after each URL batch has been exhausted.
    def after_each_run( &block )
        @after_each_run_blocks << block
    end

    def on_first_run( &block )
        @on_first_run_blocks << block
    end

    # @see Arachgni::Spider#run
    def run( *args, &block )
        @first_run_blocks ||= call_on_first_run

        if !solo?
            on_complete_blocks = @on_complete_blocks.dup
            @on_complete_blocks.clear
        end

        super( *args, &block )

        flush_url_distribution_buffer
        master_done_handler

        if slave?
            call_after_each_run
        end

        if !solo?
            @on_complete_blocks = on_complete_blocks.dup
        end

        sitemap
    end

    def update_peers( peers, &block )
        @peers_array = peers
        sorted_peers = @peers_array.inject( {} ) do |h, p|
            h[p[:url]] = framework.connect_to_instance( p )
            h
        end.sort

        @peers = Hash[sorted_peers]

        @peers[framework.self_url] = framework

        @peers = Hash[@peers.sort]

        if !master?
            block.call if block_given?
            return true
        end

        each = proc do |peer, iter|
            peer.spider.update_peers( @peers_array | [self_instance_info] ) {
                iter.return
            }
        end

        map_peers( each, proc { block.call if block_given? } )

        true
    end

    def sitemap
        @distributed_sitemap || super
    end

    def collect_sitemaps( &block )
        local_sitemap = sitemap

        if !master?
            block.call( local_sitemap )
            return
        end

        foreach = proc { |peer, iter| peer.spider.sitemap { |s| iter.return( s ) } }
        after   = proc do |sitemap|
            block.call( (sitemap | local_sitemap).flatten.uniq.sort )
        end

        map_peers( foreach, after )
    end

    def peer_done( url )
        @done_signals[url] = true
        master_done_handler
        true
    end

    def signal_if_done( master )
        master.spider.peer_done( framework.self_url ){} if done?
    end

    private

    def call_on_first_run
        @on_first_run_blocks.each( &:call )
    end

    def call_after_each_run
        @after_each_run_blocks.each( &:call )
    end

    def peer_not_done( url )
        @done_signals[url] = false
        true
    end

    def master_done_handler
        return if !master? || !done? || !slaves_done?

        # really make sure all slaves are done
        if_slaves_done do
            collect_sitemaps do |aggregate_sitemap|
                @distributed_sitemap = aggregate_sitemap
                call_on_complete_blocks
            end
        end
    end

    def if_slaves_done( &block )
        each  = proc { |peer, iter| peer.spider.running? { |b| iter.return !!b } }
        after = proc { |results| block.call if !results.include?( true )}
        map_peers( each, after )
    end

    def slaves_done?
        !@peers.reject{ |url, _| url == self_instance_info[:url] }.keys.
            map { |peer_url| @done_signals[peer_url] }.include?( false )
    end

    def master?
        framework.master?
    end

    def slave?
        framework.slave?
    end

    def solo?
        framework.solo?
    end

    def self_instance_info
        {
            url:   framework.self_url,
            token: framework.token
        }
    end

    #
    # Distributes the paths to the peers
    #
    # @param    [Array<String>]  urls    to distribute
    #
    def distribute( urls )
        urls = dedup( urls )
        return false if urls.empty?

        @first_run ||= Arachni::BloomFilter.new

        @routed          ||= {}
        @buffer_size     ||= 0
        @fillup_attempts ||= 0

        urls.each do |c_url|
            next if distributed? c_url
            @buffer_size += 1
            (@routed[route( c_url )] ||= []) << c_url
            distributed c_url
        end

        return if @buffer_size == 0

        # remove and push our URLs right way
        push( @routed.delete( framework ) )

        @fillup_attempts += 1

        return if @buffer_size < BUFFER_SIZE && @fillup_attempts < FILLUP_ATTEMPTS

        # distribute the buffered outgoing URLs
        flush_url_distribution_buffer

        true
    end

    def flush_url_distribution_buffer
        @routed ||= {}
        @routed.dup.each do |peer, r_urls|

            if !@first_run.include?( peer.url )
                @first_run << peer.url
                peer_not_done( peer.url )
            end

            peer.spider.push( r_urls ) do |included_new_paths|
                peer_not_done( peer.url ) if included_new_paths
            end
        end

        # clear the counters and the buffer
        @fillup_attempts = 0
        @buffer_size     = 0
        @routed.clear
    end

    def distributed?( url )
        @distribution_filter.include? url
    end

    def distributed( url )
        @distribution_filter << url
    end

    def map_peers( foreach, after )
        wrap = proc do |instance, iterator|
            foreach.call( instance, iterator )
        end
        peer_iterator.map( wrap, after )
    end

    def each_peer( &block )
        wrap = proc do |instance, iterator|
            block.call( instance, iterator )
        end
        peer_iterator.each( &wrap )
    end

    def peer_iterator
        ::EM::Iterator.new(
            @peers.reject{ |url, _| url == self_instance_info[:url]}.values,
            Framework::Distributor::MAX_CONCURRENCY
        )
    end

    def route( url )
        return if !url || url.empty?
        return framework if @peers.empty?
        return @peers.values.first if @peers.size == 1

        @peers.values[url.bytes.inject( :+ ).modulo( @peers.size )]
    end

    def framework
        @framework
    end

end
end
end
end
