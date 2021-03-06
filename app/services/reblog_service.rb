# frozen_string_literal: true

class ReblogService < BaseService
  include Authorization
  include StreamEntryRenderer

  # Reblog a status and notify its remote author
  # @param [Account] account Account to reblog from
  # @param [Status] reblogged_status Status to be reblogged
  # @return [Status]
  def call(account, reblogged_status)
    reblogged_status = reblogged_status.reblog if reblogged_status.reblog?

    authorize_with account, reblogged_status, :reblog?

    reblog = account.statuses.find_by(reblog: reblogged_status)

    return reblog unless reblog.nil?

    reblog = account.statuses.create!(reblog: reblogged_status, text: '')

    DistributionWorker.perform_async(reblog.id)
    Pubsubhubbub::DistributionWorker.perform_async(reblog.stream_entry.id)
    ActivityPub::DistributionWorker.perform_async(reblog.id)

    create_notification(reblog)
    reblog
  end

  private

  def create_notification(reblog)
    reblogged_status = reblog.reblog

    if reblogged_status.account.local?
      NotifyService.new.call(reblogged_status.account, reblog)
    elsif reblogged_status.account.ostatus?
      NotificationWorker.perform_async(stream_entry_to_xml(reblog.stream_entry), reblog.account_id, reblogged_status.account_id)
    elsif reblogged_status.account.activitypub?
      ActivityPub::DeliveryWorker.perform_async(build_json(reblog), reblog.account_id, reblogged_status.account.inbox_url)
    end
  end

  def build_json(reblog)
    ActiveModelSerializers::SerializableResource.new(
      reblog,
      serializer: ActivityPub::ActivitySerializer,
      adapter: ActivityPub::Adapter
    ).to_json
  end
end
