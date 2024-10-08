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
      env["INBOUND_REQUEST_LOG"] = InboundRequestLog.from_request(request)
      request.body.rewind
    end
    status, headers, body = @app.call(env)
    if logging
      updates = {response_code: status, ended_at: Time.current}
      updates[:response_body] = parsed_body(body) if log_response_body?(env)
      headers.merge!({ 'Request-Id' => env["INBOUND_REQUEST_LOG"].uuid })
      # this usually works. let's be optimistic.
      begin
        env["INBOUND_REQUEST_LOG"].update_columns(updates)
      rescue JSON::GeneratorError => _e # this can be raised by activerecord if the string is not UTF-8.
        env["INBOUND_REQUEST_LOG"].update_columns(updates.except(:response_body))
      end
    end
    [status, headers, body]
  end

  private

  def log_response_body?(env)
    skip_body_regexp.nil? || env["PATH_INFO"] !~ skip_body_regexp
  end

  def log?(env, request)
    env["PATH_INFO"] =~ path_regexp && (!only_state_change || request_with_state_change?(request))
  end

  def parsed_body(body)
    return unless body.present?

    if body.respond_to?(:body) && body.body.empty?
      {}
    elsif body.respond_to?(:to_ary)
      JSON.parse(body.to_ary[0])
    elsif body.respond_to?(:body)
      JSON.parse(body.body)
    elsif body.respond_to?(:[])
      JSON.parse(body[0])
    else
      body
    end
  rescue JSON::ParserError, ArgumentError
    body
  end

  def request_with_state_change?(request)
    request.post? || request.put? || request.patch? || request.delete?
  end
end
