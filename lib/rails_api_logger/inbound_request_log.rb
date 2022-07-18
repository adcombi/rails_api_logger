class InboundRequestLog < RequestLog
  require 'bcrypt'

  def request_body=(val)
    if val.is_a?(Hash) && (val.with_indifferent_access.key? :password)
      val[:password] = BCrypt::Password.create(val.with_indifferent_access[:password])
    end
    self[:request_body] = val
  end
end
