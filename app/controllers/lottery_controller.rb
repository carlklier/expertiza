class LotteryController < ApplicationController
  require 'json'
  require 'rest_client'

  # Give permission to run the bid to appropriate roles
  def action_allowed?
    ['Instructor',
     'Teaching Assistant',
     'Administrator'].include? current_role_name
  end

  # This method is to send request to web service and use k-means and students' bidding data to build teams automatically.
  # rubocop:disable Metrics/AbcSize
  def run_intelligent_assignment
    assignment = Assignment.find_by(id: params[:id])
    teams = assignment.teams
    # Structure of priority_info variable: [{user_id1, bids_1}, {user_id2, bids_2}]
    priority_info = construct_priority_info(assignment.sign_up_topics, teams)
    bidding_data = {users: priority_info, max_team_size: assignment.max_team_size}
    ExpertizaLogger.info LoggerMessage.new(controller_name, session[:user].name, "Bidding data for assignment #{assignment.name}: #{bidding_data}", request)
    url = WEBSERVICE_CONFIG["topic_bidding_webservice_url"]
    begin
      response = RestClient.post url, bidding_data.to_json, content_type: :json, accept: :json
      teams = JSON.parse(response)["teams"]
      ExpertizaLogger.info LoggerMessage.new(controller_name, session[:user].name, "Team formation info for assignment #{assignment.name}: #{teams}", request)
      # Structure of teams variable: [[user_id1, user_id2], [user_id3, user_id4]]
      create_new_teams_for_bidding_response(teams, assignment, priority_info)
      remove_empty_teams(assignment)
      match_new_teams_to_topics(assignment)
    rescue StandardError => e
      flash[:error] = e.message
    end
    redirect_to controller: 'tree_display', action: 'list'
  end

  private

  def construct_priority_info(sign_up_topics, teams)
    priority_info = []
    # Exclude any teams already signed up
    teams_not_signing_up = teams.select{|team| SignedUpTeam.where(team_id: team.id, is_waitlisted: 0).any?}
    teams_not_signing_up.each do |team|
      # Grab student id and list of bids
      bids = [0]
      sign_up_topics.each do |topic|
        bid_record = Bid.find_by(team_id: team.id, topic_id: topic.id)
        # use safe navigation operator to check that both bid_record and bid_record.priority exist
        bids << bid_record.priority if bid_record&.priority
      end
      # move 'if bids.uniq != [0]' outside so to avoid the looping
      team.users.each {|user| priority_info << {pid: user.id, ranks: bids}} if bids.uniq != [0]
    end
    return priority_info
  end

  def remove_empty_teams(assignment)
    assignment.teams.reload.each do |team|
      if team.teams_users.empty?
        TeamNode.where(parent_id: assignment.id, node_object_id: team.id).destroy_all rescue nil
        team.destroy
      end
    end
  end

  def create_new_teams_for_bidding_response(teams, assignment, priority_info)
    teams.each do |user_ids|
      # Create new team and team node
      new_team = AssignmentTeam.create(name: 'Team_' + rand(10_000).to_s, parent_id: assignment.id)
      team_node = TeamNode.create(parent_id: assignment.id, node_object_id: new_team.id)
      sign_up_topics = assignment.sign_up_topics
      user_ids.each do |user_id|
        # Destroy current team_user and team_user node if exists
        team_user = TeamsUser.where("user_id == ? AND team.parent_id == ? ", user_id, assignment.id)
        team_user.team_user_node.destroy rescue nil
        team_user.destroy rescue nil

        # Create new team_user and team_user node
        new_team_user = TeamsUser.create(user_id: user_id, team_id: new_team.id)
        TeamUserNode.create(parent_id: team_node.id, node_object_id: new_team_user.id)
        # Create new bids for team based on `bidding_data` variable for each team member
        # Currently, it is possible (already proved by db records) that
        # some team has multiple 1st priority, multiply 2nd priority, ....
        # these multiple identical priorities come from different previous teams
        # [Future work]: we need to find a better way to merge bids that came from different previous teams
        merge_bids_from_different_previous_teams(sign_up_topics, new_team.id, user_ids, priority_info)
      end
    end
  end

  def merge_bids_from_different_previous_teams(sign_up_topics, team_id, user_ids, priority_info)
    # Select data from `priority_info` variable that only related to team members in current team and transpose it.
    # For example, below matrix shows 4 topics (key) and correponding priorities given by 3 team members (value).
    # {
    #   1: [1, 2, 3],
    #   2: [0, 1, 2],
    #   3: [2, 3, 1],
    #   4: [2, 0, 1]
    # }
    bidding_matrix = {}
    current_team_members_info = priority_info.select{|info| user_ids.include? info[:pid]}
    current_team_members_info.map{|info| info[:ranks]}.each do |bids|
      sign_up_topics.each_with_index do |topic, index|
        bidding_matrix[topic.id] = [] unless bidding_matrix[topic.id]
        bidding_matrix[topic.id] << bids[index]
      end
    end
    # Below is the structure of matrix summary
    # The first value is the number of nonzero item, the second value is the sum of priorities, the third value of the topic_id.
    # [
    #   [3, 6, 1],
    #   [2, 3, 2],
    #   [3, 6, 3],
    #   [2, 3, 4]
    # ]
    bidding_matrix_summary = create_sorted_bidding_matrix_summary(bidding_matrix)
    # Result of soring first element descendingly and second element ascendingly.
    # We want the topic with most people bidded and lowest sum of priorities at the top.
    # [
    #   [3, 6, 1],
    #   [3, 6, 3],
    #   [2, 3, 2],
    #   [2, 3, 4]
    # ]
    # Therefore the bidding priority of these 4 topics is 1 -> 3 -> 2 -> 4
    bidding_matrix_summary.each_with_index do |b, index|
      Bid.create(topic_id: b[2], team_id: team_id, priority: index + 1)
    end
  end

  def create_sorted_bidding_matrix_summary(bidding_matrix)
    bidding_matrix_summary = []
    bidding_matrix.each do |topic_id, value|
      # Exclude topics that no one bidded
      bidding_matrix_summary << [value.count {|i| i != 0 }, value.inject(:+), topic_id] unless value.inject(:+).zero?
    end
    bidding_matrix_summary.sort! {|b1, b2| [b2[0], b1[1]] <=> [b1[0], b2[1]] }
  end

  # Generate team bidding infomation hash based on newly-created teams
  def construct_team_bidding_info(unassigned_teams, sign_up_topics)
    team_bids = []
    unassigned_teams.each do |team|
      topic_bids = []
      sign_up_topics.each do |topic|
        bid = Bid.find_by(team_id: team.id, topic_id: topic.id)
        topic_bids << {topic_id: topic.id, priority: bid.priority} if bid
      end
      topic_bids.sort! {|bid| bid[:priority] }
      team_bids << {team_id: team.id, bids: topic_bids}
    end
    return team_bids
  end

  # If certain topic has available slot(s),
  # the team with biggest size get its first-priority topic
  # then break the loop to next team
  def assign_available_slots(team_bids)
    team_bids.each do |tb|
      tb[:bids].each do |bid|
        num_of_signed_up_teams = SignedUpTeam.where(topic_id: bid[:topic_id]).count
        max_choosers = SignUpTopic.find_by(id: bid[:topic_id]).try(:max_choosers)
        if num_of_signed_up_teams < max_choosers
          SignedUpTeam.create(team_id: tb[:team_id], topic_id: bid[:topic_id])
          break
        end
      end
    end
  end

  # This method is called for assignments which have their is_intelligent property set to 1.
  # It runs a stable match algorithm and assigns topics to strongest contenders (team strength, priority of bids)
  def match_new_teams_to_topics(assignment)
    unless assignment.is_intelligent
      flash[:error] = "This action is not allowed. The assignment #{assignment.name} does not enable intelligent assignments."
      return
    end
    # Getting signup topics with max_choosers > 0
    sign_up_topics = SignUpTopic.where('assignment_id = ? and max_choosers > 0', assignment.id)
    unassigned_teams = assignment.teams.reload.select {|t|
      SignedUpTeam.where(team_id: t.id, is_waitlisted: 0).blank? and Bid.where(team_id: t.id).any?
    }
    # Sorting unassigned_teams by team size desc, number of bids in current team asc
    # again, we need to find a way to to merge bids that came from different previous teams
    # then sorting unassigned_teams by number of bids in current team (less is better)
    # and we also need to think about, how to sort teams when they have the same team size and number of bids
    # maybe we can use timestamps in this case
    unassigned_teams.sort! do |t1, t2|
      [TeamsUser.where(team_id: t2.id).size, Bid.where(team_id: t1.id).size] <=>
      [TeamsUser.where(team_id: t1.id).size, Bid.where(team_id: t2.id).size]
    end

    team_bids = construct_team_bidding_info(unassigned_teams, sign_up_topics)
    assign_available_slots(team_bids)

    # Remove is_intelligent property from assignment so that it can revert to the default signup state
    assignment.update_attributes(:is_intelligent => false)
    flash[:success] = 'The intelligent assignment was successfully completed for ' + assignment.name + '.'
  end
  # rubocop:enable Metrics/AbcSize
end
