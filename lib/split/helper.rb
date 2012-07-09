module Split
  module Helper
    def ab_test(experiment_name, control, *alternatives)

      puts 'WARNING: You should always pass the control alternative through as the second argument with any other alternatives as the third because the order of the hash is not preserved in ruby 1.8' if RUBY_VERSION.match(/1\.8/) && alternatives.length.zero?
      ret = if Split.configuration.enabled
              experiment_variable(alternatives, control, experiment_name)
            else
              control_variable(control)
            end

      if block_given?
        if defined?(capture) # a block in a rails view
          block = Proc.new { yield(ret) }
          concat(capture(ret, &block))
          false
        else
          yield(ret)
        end
      else
        ret
      end
    end

    def finished(experiment_name, options = {:reset => true})
      return if exclude_visitor? or !Split.configuration.enabled
      return unless (experiment = Split::Experiment.find(experiment_name))
      
      change_session do
        if alternative_name = @session[experiment.key]
          alternative = Split::Alternative.new(alternative_name, experiment_name)
          alternative.increment_completion
          @session.delete(experiment_name) if options[:reset]
        end
      end
    rescue => e
      raise unless Split.configuration.db_failover
      Split.configuration.db_failover_on_db_error.call(e)
    end

    def override(experiment_name, alternatives)
      params[experiment_name] if defined?(params) && alternatives.include?(params[experiment_name])
    end

    def begin_experiment(experiment, alternative_name = nil)
      alternative_name ||= experiment.control.name
      change_session { @session[experiment.key] = alternative_name }
    end

    def exclude_visitor?
      is_robot? or is_ignored_ip_address?
    end

    def not_allowed_to_test?(experiment_key)
      !Split.configuration.allow_multiple_experiments && doing_other_tests?(experiment_key)
    end

    def doing_other_tests?(experiment_key)
      get_session.keys.reject { |k| k == experiment_key }.length > 0
    end

    def clean_old_versions(experiment)
      change_session do
        old_versions(experiment).each do |old_key|
          @session.delete old_key
        end
      end
    end

    def old_versions(experiment)
      if experiment.version > 0
        get_session.keys.select { |k| k.match(Regexp.new(experiment.name)) }.reject { |k| k == experiment.key }
      else
        []
      end
    end

    def is_robot?
      request.user_agent =~ Split.configuration.robot_regex
    end

    def is_ignored_ip_address?
      if Split.configuration.ignore_ip_addresses.any?
        Split.configuration.ignore_ip_addresses.include?(request.ip)
      else
        false
      end
    end

    def get_session
      if cookies.signed[:split]
        Marshal.load(cookies.signed[:split])
      else
        {}
      end
    end

    def set_session(value)
      cookie = {value: Marshal.dump(value)}
      cookie[:expires] = Split.configuration.cookie_expires if Split.configuration.cookie_expires
      cookie[:domain] = Split.configuration.cookie_domain if Split.configuration.cookie_domain

      cookies.signed[:split] = cookie
    end

    def change_session
      @session = get_session

      yield @session if block_given?

      set_session(@session)
    end

    protected

    def control_variable(control)
      Hash === control ? control.keys.first : control
    end

    def experiment_variable(alternatives, control, experiment_name)
      begin
        experiment = Split::Experiment.find_or_create(experiment_name, *([control] + alternatives))
        if experiment.winner
          ret = experiment.winner.name
        else
          if forced_alternative = override(experiment.name, experiment.alternative_names)
            ret = forced_alternative
          else
            clean_old_versions(experiment)
            begin_experiment(experiment) if exclude_visitor? or not_allowed_to_test?(experiment.key)

            if get_session[experiment.key]
              ret = get_session[experiment.key]
            else
              alternative = experiment.next_alternative
              alternative.increment_participation
              begin_experiment(experiment, alternative.name)
              ret = alternative.name
            end
          end
        end
      rescue => e
        raise unless Split.configuration.db_failover
        Split.configuration.db_failover_on_db_error.call(e)
        ret = control_variable(control)
      end
      ret
    end

  end

end
