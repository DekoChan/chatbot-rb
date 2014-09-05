require 'httparty'
require 'media_wiki'
require 'logger'
require_relative './plugin'
require_relative './util'

$logger = Logger.new(STDERR)
$logger.level = Logger::WARN

module Chatbot
  class Client
    include HTTParty

    USER_AGENT = 'sactage/chatbot-rb v1.0.0'
    CONFIG_FILE = 'config.yml'
    SOCKET_EVENTS = {'1::' => :on_socket_connect, '4:::' => :on_socket_message, '8::' => :on_socket_ping}

    attr_accessor :session, :clientid, :handlers, :config, :userlist, :api, :threads
    attr_reader :plugins

    def initialize
      unless File.exists? CONFIG_FILE
        $logger.fatal "Config: #{CONFIG_FILE} not found!"
        exit
      end

      @config = YAML::load_file CONFIG_FILE
      @base_url = @config.key?('dev') ? "http://localhost:8080" : "http://#{@config['wiki']}.wikia.com"
      @api = MediaWiki::Gateway.new @base_url + '/api.php'
      @api.login(@config['user'], @config['password'])
      @t = 0
      @headers = {
          'User-Agent' => USER_AGENT,
          'Cookie' => @api.cookies.map { |k, v| "#{k}=#{v};" }.join(' ') + ' io=VQF8sXJkKNFVfo9wAAUi;',
          'Content-type' => 'text/plain;charset=UTF-8',
          'Pragma' => 'no-cache',
          'Cache-Control' => 'no-cache',
          'Connection' => 'keep-alive',
          'Accept' => '*/*',

      }
      @userlist = {}
      @userlist_mutex = Mutex.new
      @running = true
      fetch_chat_info
      @threads = []
      @plugins = []
      @handlers = {
          :message => [],
          :join => [],
          :part => [],
          :kick => [],
          :logout => [],
          :ban => [],
          :update_user => [],
          :quitting => []
      }
    end

    def register_plugins(*plugins)
      plugins.each do |plugin|
        @plugins << plugin.new(self)
        @plugins.last.register
      end
    end

    def save_config
      File.open(CONFIG_FILE, File::WRONLY) {|f| f.write(@config.to_yaml)}
    end

    def fetch_chat_info
      res = HTTParty.get("#{@base_url}/wikia.php?controller=Chat&format=json", :headers => @headers)
      data = JSON.parse(res.body, :symbolize_names => true)
      @key = data[:chatkey]
      @server = data[:nodeInstance]
      @room = data[:roomId]
      @mod = data[:isChatMod]
      @request_options = {
          :user => @config['user'],
          :EIO => 2,
          :transport => 'polling',
          :key => @key,
          :roomId => @room,
          :serverId => @server
      }
      if @config.key?('dev')
        self.class.base_uri "http://#{data[:nodeHostname]}:#{data[:nodePort]}/"
      else
        self.class.base_uri "http://#{data[:nodeHostname]}/"
      end
      @request_options[:sid] = get.headers['set-cookie'].gsub(/io=/,'')
      @headers['Cookie'] += " io=#{@request_options[:sid]};"
      #@session = get.body.match(/\d+/)[0] # *probably* should check for nil here and rescue, but I'm too lazy
    end

    def get(path: '/socket.io/')
      opts = @request_options.merge({:t => Time.now.to_ms.to_s + '-' + @t.to_s})
      @t +=1
      self.class.get(path, :query => opts, :headers => @headers)
    end

    def post(body, path: '/socket.io/')
      opts = @request_options.merge({:t => Time.now.to_ms.to_s + '-' + @t.to_s})
      @t += 1
      self.class.post(path, :query => opts, :body => body, :headers => @headers)
    end

    def run!
      while @running
        begin
          res = get
          $logger.warn res
          body = res.body
          if body.include? "\xef\xbf\xbd"
            body.split(/\xef\xbf\xbd/).each do |part|
              next unless part.size > 10
              event = part.match(/\d:::?/)[0]
              data = part.sub(event, '')
              @threads << Thread.new(event, data) {
                case event
                  when '1::'
                    on_socket_connect
                  when '8::'
                    on_socket_ping
                  when '4:::'
                    on_socket_message(data)
                  else
                    1
                end
              }
            end
          else
            event = body.match(/\d:::?/)[0]
            data = body.sub(event, '')
            @threads << Thread.new(event, data) {
              case event
                when '1::'
                  on_socket_connect
                when '8::'
                  on_socket_ping
                when '4:::'
                  on_socket_message(data)
                else
                  1
              end
            }
          end
        rescue Net::ReadTimeout => e
          $logger.fatal e
          @running = false
        end
      end
      @handlers[:quitting].each {|handler| handler.call(nil)}
      @threads.each { |thr| thr.join }
    end

    # BEGIN socket event methods
    def on_socket_connect
      $logger.info 'Connected to chat!'
    end

    def on_socket_message(msg)
      begin
        json = JSON.parse(msg)
        json['data'] = JSON.parse(json['data'])
        if json['event'] == 'chat:add' and not json['data']['id'].nil?
          json['event'] = 'message'
        elsif json['event'] == 'updateUser'
          json['event'] = 'update_user'
        end
        begin
          self.method("on_chat_#{json['event']}".to_sym).call(json['data'])
        rescue NameError
          $logger.debug 'ignoring un-used event'
        end
        @handlers[json['event'].to_sym].each {|handler| handler.call(json['data'])} if json['event'] != 'message' and @handlers.key? json['event'].to_sym
      rescue => e
        $logger.fatal e
      end
    end

    def on_socket_ping
      post('8::')
    end

    # END socket event methods

    # BEGIN chat event methods
    def on_chat_message(data)
      begin
        message = data['attrs']['text']
        user = @userlist[data['attrs']['name']]
        $logger.info "<#{user.name}> #{message}"
        @handlers[:message].each { |handler| handler.call(message, user) }
      rescue => e
        $logger.fatal e
      end
    end

    def on_chat_initial(data)
      data['collections']['users']['models'].each do |user|
        attrs = user['attrs']
        @userlist[attrs['name']] = User.new(attrs['name'], attrs['isModerator'], attrs['isCanGiveChatMod'], attrs['isStaff'])
      end
    end

    def on_chat_join(data)
      if data['attrs']['name'] == @config['user'] and @clientid.nil?
        @clientid = data['cid']
        post('3:::{"id":null,"cid":"' + @clientid + '","attrs":{"msgType":"command","command":"initquery"}}')
      end
      $logger.info "#{data['attrs']['name']} joined the chat"
      @userlist_mutex.synchronize do
        @userlist[data['attrs']['name']] = User.new(data['attrs']['name'], data['attrs']['isModerator'], data['attrs']['isCanGiveChatMod'], data['attrs']['isStaff'])
      end
    end

    def on_chat_part(data)
      $logger.info "#{data['attrs']['name']} left the chat"
      @userlist_mutex.synchronize do
        @userlist.delete(data['attrs']['name'])
      end
    end

    def on_chat_logout(data)
      $logger.info "#{data['attrs']['name']} left the chat"
      @userlist_mutex.synchronize do
        @userlist.delete(data['attrs']['name'])
      end
    end
    # END chat event methods

    # BEGIN chat interaction methods
    def send_msg(text)
      post('5:::{"name":"message","args":["{\"attrs\":{\"msgType\":\"chat\",\"text\":\"' + text.gsub('"', '\\"') + '\"}}"]}')
    end

    def kick(user)
      post('3:::{"id":null,"cid":"%s","attrs":{"msgType":"command","command":"kick","userToKick":"%s"}}' % [@clientid, user.gsub(/"/, "\\\"").gsub("\\", "\\\\")])
    end

    def quit
      @running = false
      post('3:::{"id":null,"cid":"'+ @clientid + '","attrs":{"msgType":"command","command":"logout"}}')
    end
  end
end
