module Backup
  class CLI
    desc 'outbox:upload', 'Retry uploading an existing outbox package'

    method_option :trigger,
                  aliases: '-t',
                  required: true,
                  type: :string,
                  desc: 'Exact model trigger to load'

    method_option :time,
                  required: true,
                  type: :string,
                  desc: 'Existing package time in YYYY.MM.DD.HH.MM.SS format'

    method_option :storage,
                  aliases: '-s',
                  type: :string,
                  desc: 'Optional Outbox storage identifier'

    method_option :config_file,
                  aliases: '-c',
                  type: :string,
                  default: '',
                  desc: 'Path to the Backup configuration file'

    define_method 'outbox:upload' do
      run_outbox_command do |outbox|
        outbox.retry_upload!(options[:time])
      end
    end

    desc 'outbox:cleanup', 'Remove expired local data for an Outbox storage'

    method_option :trigger,
                  aliases: '-t',
                  required: true,
                  type: :string,
                  desc: 'Exact model trigger to load'

    method_option :storage,
                  aliases: '-s',
                  type: :string,
                  desc: 'Optional Outbox storage identifier'

    method_option :config_file,
                  aliases: '-c',
                  type: :string,
                  default: '',
                  desc: 'Path to the Backup configuration file'

    define_method 'outbox:cleanup' do
      run_outbox_command(&:cleanup!)
    end

    no_commands do
      def run_outbox_command
        configure_outbox_logger
        Config.load(options)
        outboxes = selected_outboxes
        Logger.start!
        outboxes.each { yield it }
      rescue StandardError => e
        Logger.error Error.wrap(e)
        Logger.error e.backtrace.join("\n") unless Helpers.is_backup_error?(e)
        Logger.abort!
        exit 2
      end

      def configure_outbox_logger
        Logger.configure do
          console.quiet = false
          logfile.enabled = false
          syslog.enabled = false
        end
      end

      def selected_outboxes
        trigger = Path.component(options[:trigger], 'Model Trigger')
        models = Model.find_by_trigger(trigger)
        raise Error, "No Model found for trigger '#{trigger}'" if models.empty?

        outboxes = models.flat_map do |model|
          model.storages.select { it.is_a?(Storage::Outbox) }
        end
        outboxes.select! { it.storage_id == options[:storage] } if options[:storage]
        raise Error, "No matching Outbox storage found for '#{trigger}'" if outboxes.empty?

        outboxes
      end
    end
  end
end
