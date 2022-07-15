class InboundRequestLog < RequestLog
  require 'bcrypt'

  def request_body=(val)
    if val.with_indifferent_access.key? :password
      val[:password] = BCrypt::Password.create(val[:password])
    end
    self[:request_body] = val
  end
end
