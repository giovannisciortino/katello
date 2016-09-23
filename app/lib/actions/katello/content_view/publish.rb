# rubocop:disable HandleExceptions
module Actions
  module Katello
    module ContentView
      class Publish < Actions::EntryAction
        middleware.use Actions::Middleware::KeepCurrentUser

        # rubocop:disable MethodLength
        def plan(content_view, description = "")
          action_subject(content_view)
          content_view.check_ready_to_publish!
          version = content_view.create_new_version(description)
          library = content_view.organization.library

          history = ::Katello::ContentViewHistory.create!(:content_view_version => version,
                                                          :user => ::User.current.login,
                                                          :status => ::Katello::ContentViewHistory::IN_PROGRESS,
                                                          :action => ::Katello::ContentViewHistory.actions[:publish],
                                                          :task => self.task)

          sequence do
            plan_action(ContentView::AddToEnvironment, version, library)
            concurrence do
              content_view.repositories_to_publish_by_library_instance.each do |_library_instance, repositories|
                sequence do
                  clone_to_version = plan_action(Repository::CloneToVersion, repositories, version)
                  plan_action(Repository::CloneToEnvironment, clone_to_version.new_repository, library)
                end
              end

              sequence do
                has_modules = content_view.publish_puppet_environment?
                plan_action(ContentViewPuppetEnvironment::CreateForVersion, version)
                plan_action(ContentViewPuppetEnvironment::Clone, version, :environment => library,
                            :puppet_modules_present => has_modules)
              end

              repos_to_delete(content_view).each do |repo|
                plan_action(Repository::Destroy, repo, :skip_environment_update => true, :planned_destroy => true)
              end
            end

            plan_action(ContentView::UpdateEnvironment, content_view, library)
            plan_action(Katello::Foreman::ContentUpdate, library, content_view)
            plan_action(ContentView::ErrataMail, content_view, library)
            plan_self(history_id: history.id, content_view_id: content_view.id,
                      environment_id: library.id, user_id: ::User.current.id)
          end
        end

        def humanized_name
          _("Publish")
        end

        def run
          environment = ::Katello::KTEnvironment.find(input[:environment_id])
          if ::Katello::CapsuleContent.sync_needed?(environment)
            ForemanTasks.async_task(ContentView::CapsuleGenerateAndSync,
                                    ::Katello::ContentView.find(input[:content_view_id]),
                                    environment)
          end
        rescue ::Katello::Errors::CapsuleCannotBeReached # skip any capsules that cannot be connected to
        end

        def rescue_strategy_for_self
          Dynflow::Action::Rescue::Skip
        end

        def finalize
          history = ::Katello::ContentViewHistory.find(input[:history_id])
          history.status = ::Katello::ContentViewHistory::SUCCESSFUL
          history.save!
        end

        private

        def repos_to_delete(content_view)
          if content_view.composite?
            library_instances = content_view.repositories_to_publish.map(&:library_instance_id)
          else
            library_instances = content_view.repositories_to_publish.map(&:id)
          end
          content_view.repos(content_view.organization.library).find_all do |repo|
            !library_instances.include?(repo.library_instance_id)
          end
        end
      end
    end
  end
end
