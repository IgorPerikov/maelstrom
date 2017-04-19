#!/usr/bin/ruby

require 'json'
require 'thread'
require 'set'

class Logger
  @@lock = Mutex.new

  def <<(*args)
    @@lock.synchronize do
      STDERR.puts *args
    end
  end
end

class Log
  def initialize(logger)
    @logger = logger
    @entries = [{term: 0, op: nil}]
  end

  # Raft's log is 1-indexed
  def [](i)
    @entries[i-1]
  end

  def <<(entry)
    @entries << entry
    @logger << "Log: #{@entries.inspect}"
  end

  def append(entries)
    @entries += entries
    @logger << "Log: #{@entries.inspect}"
  end

  def last
    @entries[-1]
  end

  def last_term
    if l = last
      l[:term]
    else
      0
    end
  end

  def size
    @entries.size
  end

  # Truncate log to length len
  def truncate(len)
    @entries.slice! len...size
  end

  # Entries from index i onwards
  def from(i)
    raise "illegal index #{i}" unless 0 < i
    @entries.slice(i - 1 .. -1)
  end
end

class Client
  attr_accessor :node_id

  def initialize(logger)
    @node_id = nil
    @logger = logger
    @lock = Monitor.new
    @next_msg_id = 0
    @handlers = {}
    @callbacks = {}
  end

  # Generate a fresh message id
  def new_msg_id
    @lock.synchronize do
      @next_msg_id += 1
    end
  end

  # Register a new message type handler
  def on(type, &handler)
    @lock.synchronize do
      if @handlers[type]
        raise "Already have a handler for #{type}!"
      end

      @handlers[type] = handler
    end
  end

  # Send a body to the given node id
  def send!(dest, body)
    @lock.synchronize do
      @logger << "Sent #{{dest: dest, src: @node_id, body: body}.inspect}"
      JSON.dump({dest: dest,
                 src:  @node_id,
                 body: body},
                STDOUT)
      STDOUT << "\n"
      STDOUT.flush
    end
  end

  # Reply to a request with a response body
  def reply!(req, body)
    body[:in_reply_to] = req[:body][:msg_id]
    send! req[:src], body
  end

  # Send an RPC request
  def rpc!(dest, body, &handler)
    @lock.synchronize do
      msg_id = new_msg_id
      @callbacks[msg_id] = handler
      body[:msg_id] = msg_id
      send! dest, body
    end
  end

  # Starts a thread to handle incoming messages
  def start!
    Thread.new do
      while true
        begin
          msg = JSON.parse(STDIN.gets, symbolize_names: true)
          @logger << "Received #{msg.inspect}"

          handler = nil
          @lock.synchronize do
            if handler = @callbacks[msg[:body][:in_reply_to]]
              @callbacks.delete msg[:body][:in_reply_to]
            elsif handler = @handlers[msg[:body][:type]]
            else
              raise "No callback or handler for #{msg.inspect}"
            end
          end
          handler.call msg
        rescue Exception => e
          @logger << "Error in client input thread! #{e}\n#{e.backtrace.join "\n"}"
        end
      end
    end
  end
end

class KVStore
  def initialize(logger)
    @logger = logger
    @state = {}
  end

  # Apply op to state machine and generate a response message
  def apply!(op)
    @logger << "Applying #{op}"
    res = nil
    k = op[:key]
    case op[:type]
    when "read"
      if @state.include? k
        res = {type: "read_ok", value: @state[op[:key]]}
      else
        res = {type: "error", code: 20, text: "not found"}
      end
    when "write"
      @state[k] = op[:value]
      res = {type: "write_ok"}
    when "cas"
      if not @state.include? k
        res = {type: "error", code: 20, text: "not found"}
      elsif @state[k] != op[:from]
        res = {type: "error",
               code: 22,
               text: "expected #{op[:from]}, had #{@state[k]}"}
      else
        @state[k] = op[:to]
        res = {type: "cas_ok"}
      end
    end
    @logger << "KV: #{@state.inspect}"

    res[:in_reply_to] = op[:msg_id]
    {dest: op[:client], body: res}
  end
end

class RaftNode
  def initialize
    @election_timeout = 2.0
    @election_deadline = Time.at 0
    @heartbeat_deadline = Time.at 0

    @logger = Logger.new

    @node_id     = nil
    @node_ids    = nil

    # Raft state
    @current_term = 0
    @voted_for    = nil
    @log          = Log.new @logger

    @commit_index = 0
    @last_applied = 1

    @lock = Monitor.new
    @client = Client.new @logger
    @state_machine = KVStore.new @logger
    setup_handlers!

    @state = :nascent
  end

  # What number would constitute a majority of n nodes?
  def majority(n)
    (n / 2.0 + 1).floor
  end

  # Given a collection of elements, finds the median, biasing towards lower
  # values if there's a tie.
  def median(xs)
    xs.sort[xs.size - majority(xs.size)]
  end

  def other_nodes
    @node_ids - [@node_id]
  end

  def next_index
    m = @next_index.dup
    m[@node_id] = @log.size + 1
    m
  end

  def match_index
    m = @match_index.dup
    m[@node_id] = @log.size
    m
  end

  def node_id=(id)
    @node_id = id
    @client.node_id = id
  end

  # Broadcast RPC
  def brpc!(body, &handler)
    other_nodes.each do |node_id|
      @client.rpc! node_id, body, &handler
    end
  end


  ## Basic transitions #######################################################

  def reset_election_deadline!
    @election_deadline = Time.now + (@election_timeout * (rand + 1))
  end

  def reset_heartbeat_deadline!
    @heartbeat_deadline = Time.now + (@election_timeout / 2.0)
  end

  def advance_term!(term)
    @lock.synchronize do
      raise "Can't go backwards" unless @current_term < term
      @current_term = term
      @voted_for = nil
    end
  end


  ## Transitions between roles ###############################################

  def become_follower!
    @lock.synchronize do
      @logger << "Became follower for term #{@current_term}"
      @state = :follower
      @next_index = nil
      @match_index = nil
    end
  end

  def become_candidate!
    @lock.synchronize do
      @state = :candidate
      advance_term! @current_term + 1
      @voted_for = @node_id
      @logger << "Became candidate for term #{@current_term}"
      reset_election_deadline!
      request_votes!
    end
  end

  def become_leader!
    @lock.synchronize do
      raise "Should be a candidate" unless @state == :candidate
      @logger << "Became leader for term #{@current_term}"
      @state = :leader
      @next_index = Hash[other_nodes.zip([@log.size + 1] * other_nodes.size)]
      @match_index = Hash[other_nodes.zip([0] * other_nodes.size)]
    end
  end

  ## Rules for all servers ##################################################

  def advance_state_machine!
    @lock.synchronize do
      if @last_applied < @commit_index
        @last_applied += 1
        res = @state_machine.apply! @log[@last_applied][:op]
        if @state == :leader
          @logger << "KV response: #{res.inspect}"
          @client.send! res[:dest], res[:body]
        end
      end
    end
  end

  def maybe_step_down!(remote_term)
    @lock.synchronize do
      if @current_term < remote_term
        advance_term! remote_term
        become_follower!
      end
    end
  end


  ## Rules for leaders ######################################################

  def replicate_log!(force)
    sent = false
    @lock.synchronize do
      if @state == :leader
        other_nodes.each do |node|
          ni = @next_index[node]
          if force or ni <= @log.size
            entries = @log.from ni
            @client.rpc!(
              node,
              type:            "append_entries",
              term:            @current_term,
              leader_id:       @node_id,
              prev_log_index:  ni - 1,
              prev_log_term:   @log[ni - 1][:term],
              entries:         entries,
              leader_commit:   @commit_index
            ) do |res|
              body = res[:body]
              @lock.synchronize do
                if body[:success]
                  @next_index[node] =
                    [@next_index[node], ni + entries.size].max
                  @match_index[node] =
                    [@match_index[node], ni - 1 + entries.size].max
                else
                  @next_index[node] -= 1
                end
              end
            end
            reset_heartbeat_deadline!
            sent = true
          end
        end
      end
    end

    if sent
      sleep 1
    end
  end

  def leader_advance_commit_index!
    @lock.synchronize do
      if @state == :leader
        n = median match_index.values
        if @commit_index < n and @log[n][:term] == @current_term
          @commit_index = n
        end
      end
    end
  end


  ## Leader election ########################################################

  def request_votes!
    votes = Set.new([@node_id])

    @lock.synchronize do
      brpc!(
        type:            "request_vote",
        term:            @current_term,
        candidate_id:    @node_id,
        last_log_index:  @log.size,
        last_log_term:   @log.last_term
      ) do |response|
        body = response[:body]
        @lock.synchronize do
          case body[:type]
          when "request_vote_res"
            maybe_step_down! body[:term]
            if @state == :candidate and body[:vote_granted] and body[:term] == @current_term
              # Got a vote for our candidacy
              votes << response[:src]
              if majority(@node_ids.size) <= votes.size
                # We have a majority of votes for this term
                become_leader!
              end
            end
          else
            raise "Unknown response message: #{response.inspect}"
          end
        end
      end
    end
  end


  def heartbeat!
    @lock.synchronize do
      if @state == :leader
        dt = @heartbeat_deadline - Time.now
        if (0 < dt)
          sleep dt
        else
          replicate_log! true
        end
      end
    end
  end

  ## Threads ###############################################################

  # Spawns a thread to periodically perform elections
  def election_thread!
    Thread.new do
      while true
        begin
          dt = (@election_deadline - Time.now)
          if (dt <= 0)
            if (@state == :follower or @state == :candidate)
              # Time for an election!
              become_candidate!
            else
              # We're a leader or initializing, sleep again
              reset_election_deadline!
            end
          else
            sleep dt
          end
        rescue Exception => e
          @logger << "Election thread caught #{e}:\n#{e.backtrace.join("\n")}"
        end
      end
    end
  end

  # Spawns a thread to replicate the leader's log
  def transition_thread!
    Thread.new do
      while true
        begin
          replicate_log! false
          heartbeat!
          leader_advance_commit_index!
          advance_state_machine!
          sleep 0.2
        rescue Exception => e
          @logger << "Caught #{e}:\n#{e.backtrace.join "\n"}"
        end
      end
    end
  end

  ## Top-level message handlers #############################################

  def add_log_entry!(msg)
    body = msg[:body]
    @lock.synchronize do
      if @state == :leader
        body[:client] = msg[:src]
        @log << {term: @current_term, op: body}
      else
        @client.reply! msg, {type: "error", code: 11, text: "not a leader"}
      end
    end
  end

  def setup_handlers!
    @client.on "raft_init" do |msg|
      @lock.synchronize do
        raise "Can't init twice!" unless @state == :nascent

        body = msg[:body]
        self.node_id = body[:node_id]
        @node_ids = body[:node_ids]
        @logger << "Raft init!"
        @client.reply! msg, {type: "raft_init_ok"}

        reset_election_deadline!
        become_follower!
        election_thread!
      end
    end

    @client.on "request_vote" do |msg|
      body = msg[:body]
      @lock.synchronize do
        maybe_step_down! body[:term]
        grant = false
        if (body[:term] < @current_term)
        elsif (@voted_for == nil or @voted_for == body[:candidate_id]) and
          @log.last_term <= body[:last_log_term] and
          @log.size <= body[:last_log_index]

          grant = true
          @voted_for = body[:candidate_id]
          reset_election_deadline!
        end

        @client.reply! msg, {type: "request_vote_res",
                             term: @current_term,
                             vote_granted: grant}
      end
    end

    @client.on "append_entries" do |msg|
      body = msg[:body]
      @lock.synchronize do
        maybe_step_down! body[:term]
        reset_election_deadline!

        ok  = {type: "append_entries_res", term: @current_term, success: true}
        err = {type: "append_entries_res", term: @current_term, success: false}
        if body[:term] < @current_term
          # Leader is behind us
          @client.reply! msg, err
        elsif 0 < body[:prev_log_index] and e = @log[body[:prev_log_index]] and (e.nil? or e[:term] != body[:prev_log_term])
          # We disagree on the previous log term
          @client.reply! msg, err
        else
          # OK, we agree on the previous log term now. Truncate and append
          # entries.
          @log.truncate body[:prev_log_index]
          @log.append body[:entries]

          # Advance commit pointer
          if @commit_index < body[:leader_commit]
            @commit_index = [body[:leader_commit], @log.size].min
          end

          @client.reply! msg, ok
        end
      end
    end

    @client.on "read"  do |msg| add_log_entry! msg end
    @client.on "write" do |msg| add_log_entry! msg end
    @client.on "cas"   do |msg| add_log_entry! msg end
  end


  ## Lifecycle ##############################################################

  def start!
    begin
      @client.start!
      transition_thread!
      @logger << "Online"
      while true
        sleep 1
      end
    rescue Exception => e
      @logger << "Error starting node: #{e}"
    end
  end
end

RaftNode.new.start!