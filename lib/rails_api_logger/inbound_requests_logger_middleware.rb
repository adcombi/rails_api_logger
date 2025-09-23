# frozen_string_literal: true

class InboundRequestsLoggerMiddleware
  attr_accessor :only_state_change, :path_regexp, :skip_body_regexp

  def initialize(app, only_state_change: true, path_regexp: /.*/, skip_body_regexp: nil)
    @app = app
    self.only_state_change = only_state_change
    self.path_regexp = path_regexp
    self.skip_body_regexp = skip_body_regexp
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    logging = log?(env, request)
    if logging
      env['INBOUND_REQUEST_LOG'] = InboundRequestLog.from_request(request)
      begin
        io = request.body
        io.rewind if io.respond_to?(:rewind)
      rescue StandardError
        # no-op: some Rack setups may not provide a rewindable body
      end
    end
    status, headers, body = @app.call(env)
    if logging
      updates = { response_code: status, ended_at: Time.current }
      updates[:response_body] = parsed_body(body) if log_response_body?(env)
      headers.merge!({ 'Request-Id' => env['INBOUND_REQUEST_LOG'].uuid })
      # this usually works. let's be optimistic.
      begin
        env['INBOUND_REQUEST_LOG'].update_columns(updates)
      rescue JSON::GeneratorError => _e # this can be raised by activerecord if the string is not UTF-8.
        env['INBOUND_REQUEST_LOG'].update_columns(updates.except(:response_body))
      end
    end
    [status, headers, body]
  end

  private

  def log_response_body?(env)
    skip_body_regexp.nil? || env['PATH_INFO'] !~ skip_body_regexp
  end

  def log?(env, request)
    env['PATH_INFO'] =~ path_regexp && (!only_state_change || request_with_state_change?(request))
  end

  def parsed_body(body)
    return if body.nil?

    # Extract a raw string from various Rack body types without returning complex objects
    raw =
      if body.respond_to?(:body) && body.body.respond_to?(:empty?) && body.body.empty?
        return {}
      elsif body.is_a?(String)
        body
      elsif body.respond_to?(:to_ary)
        (ary = body.to_ary) && ary.respond_to?(:first) ? ary.first : nil
      elsif body.respond_to?(:each)
        first_chunk = nil
        body.each do |chunk|
          first_chunk = chunk
          break
        end
        first_chunk
      elsif body.respond_to?(:body)
        body.body
      elsif body.respond_to?(:[])
        body[0]
      else
        body
      end

    raw = (raw.is_a?(String) ? raw : raw.to_s)

    begin
      if raw.bytesize.positive? && [123, 91].include?(raw.getbyte(0)) # '{' or '['
        JSON.parse(raw)
      else
        raw
      end
    rescue JSON::ParserError, ArgumentError, TypeError
      raw
    end
  end

  def request_with_state_change?(request)
    request.post? || request.put? || request.patch? || request.delete?
  end
end
