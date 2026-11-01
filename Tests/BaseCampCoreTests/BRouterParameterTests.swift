import BaseCampCore
import XCTest

/// The settings at the top of a BRouter profile, offered per routing profile and sent as `profile:name=value`.
final class BRouterParameterTests: XCTestCase {
    /// As the top of BRouter's mtb profile: plain values, no descriptions for BRouter's web page.
    private let mtb = """
      # MTB profile
      ---context:global

      assign   add_beeline            false  # %add_beeline% | Enable beeline on distant start/end points | boolean
      assign   iswet                  0 # 0 as default, *) flag for weather conditions
      assign   MTB_factor             0.0 # default 0.0, *)
      assign   smallpaved_factor      -0.5 # default 0.0, *)
      assign   hills                  0 # 1=default / 0=BRouter default
      assign   path_preference        20.0 # 20.0 as default
      assign   allow_steps            0 # 1 as default
      assign   uphillcostvalue        switch equal hills 1 70   switch equal hills 2 80
                                      0
      assign   uphillcost             uphillcostvalue

      ---context:way
      assign   allow_ferries          1
    """

    /// As the top of the trekking and fast-bike profiles, with descriptions and types.
    private let annotated = """
    ---context:global
    assign   allow_steps              = true   # %allow_steps% | Set false to disallow steps | boolean
    assign   use_proposed_cycleroutes = false  # %use_proposed_cycleroutes% | Set to true to consider proposed and regular cycleroutes as equals | boolean
    assign consider_traffic      = 0.1      # %consider_traffic% | avoiding roads that usually have traffic is? | [1=very important, 0.5=pretty important, 0.0=do not consider traffic]
    assign uphillcost         = 0     # %uphillcost% | Cost for going uphill | number
    assign turnInstructionMode          = 1     # %turnInstructionMode% | Mode for the generated turn instructions | [0=none, 1=auto-choose]
    assign totalMass  = 90     # %totalMass% | Mass (in kg) of the bike + biker, for travel time computation | number
    assign elevationpenaltybuffer     5    # 5 as default
    ---context:way
    """

    func testPlainSettingsAreFoundWithTheirValuesInHighCampsOrder() throws {
        let parameters = BRouterParameters.parse(mtb)
        XCTAssertEqual(parameters.map(\.name), ["hills", "allow_steps", "path_preference", "MTB_factor", "smallpaved_factor", "iswet"])
        XCTAssertTrue(parameters.allSatisfy(\.isMain))
        let hills = try XCTUnwrap(parameters.first)
        XCTAssertEqual(hills.label, "Climbs")
        guard case .choice(let choices) = hills.kind else { return XCTFail("hills is a choice") }
        XCTAssertEqual(choices.first, BRouterParameter.Choice(0, "BRouter's default"))
        XCTAssertEqual(parameters.first { $0.name == "smallpaved_factor" }?.defaultValue, -0.5)
        XCTAssertEqual(parameters.first { $0.name == "allow_steps" }?.kind, .toggle)
        // Worked out from other settings (uphillcost), or after the global context (allow_ferries): not offered.
        XCTAssertNil(parameters.first { $0.name == "uphillcost" })
        XCTAssertNil(parameters.first { $0.name == "allow_ferries" })
    }

    func testDescribedSettingsTakeTheProfilesTypesAndOthersAreLeftOut() throws {
        let parameters = BRouterParameters.parse(annotated)
        XCTAssertEqual(parameters.map(\.name), ["uphillcost", "allow_steps", "consider_traffic", "use_proposed_cycleroutes"])
        XCTAssertEqual(parameters.first { $0.name == "allow_steps" }?.defaultValue, 1)
        // HighCamp's label, the profile's own list of values.
        let traffic = try XCTUnwrap(parameters.first { $0.name == "consider_traffic" })
        XCTAssertEqual(traffic.label, "Avoid traffic")
        XCTAssertEqual(traffic.kind, .choice([.init(1, "very important"), .init(0.5, "pretty important"), .init(0, "do not consider traffic")]))
        // Described but not in HighCamp's list: offered under its own name and description.
        let proposed = try XCTUnwrap(parameters.last)
        XCTAssertFalse(proposed.isMain)
        XCTAssertEqual(proposed.label, "Use proposed cycleroutes")
        XCTAssertEqual(proposed.help, "Set to true to consider proposed and regular cycleroutes as equals")
    }

    func testTheRequestCarriesTheChangedSettingsAsNumbers() throws {
        let url = BRouterClient.requestURL(baseURL: URL(string: "http://127.0.0.1:17778")!, profile: "mtb",
                                           options: ["path_preference": 0, "MTB_factor": 0.3, "allow_steps": 1], via: [], nogos: [])
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name.hasPrefix("profile:") }.map { "\($0.name)=\($0.value ?? "")" },
                       ["profile:MTB_factor=0.3", "profile:allow_steps=1", "profile:path_preference=0"])
    }

    func testProfilesKeepTheirSettingsAndOldOnesReadWithout() throws {
        let profile = RoutingProfile(name: "Wet", brouterProfile: "mtb", brouterOptions: ["iswet": 1])
        XCTAssertEqual(try JSONDecoder().decode(RoutingProfile.self, from: JSONEncoder().encode(profile)).brouterOptions, ["iswet": 1])
        let old = #"{"id":"6A1F0C3E-0001-4B2E-9C11-000000000001","name":"Old","brouterProfile":"mtb"}"#
        XCTAssertEqual(try JSONDecoder().decode(RoutingProfile.self, from: Data(old.utf8)).brouterOptions, [:])
        XCTAssertNil(try JSONDecoder().decode(RoutingProfile.self, from: Data(old.utf8)).maxClimbPercent)
        XCTAssertEqual(try JSONDecoder().decode(RoutingProfile.self, from: Data(old.utf8)).minimumDetourMeters, 1000)
    }

    func testAClimbingLimitIsSentAsBRoutersMaximumSlope() throws {
        var profile = RoutingProfile(name: "MTB", brouterProfile: "mtb", maxClimbPercent: 20, brouterOptions: ["hills": 1])
        XCTAssertEqual(profile.requestOptions, ["uphillmaxslope": 20, "uphillmaxslopecost": 100_000, "hills": 1])
        profile.brouterOptions["uphillmaxslopecost"] = 500
        XCTAssertEqual(profile.requestOptions["uphillmaxslopecost"], 500, "a setting chosen for the profile wins")
        profile.maxClimbPercent = nil
        XCTAssertEqual(profile.requestOptions, ["hills": 1, "uphillmaxslopecost": 500])
        XCTAssertEqual(try JSONDecoder().decode(RoutingProfile.self, from: JSONEncoder().encode(RoutingProfile(name: "A", brouterProfile: "mtb", maxClimbPercent: 18))).maxClimbPercent, 18)
        XCTAssertEqual(RoutingProfile.defaults.filter { $0.maxGradePercent != nil }.map(\.maxClimbPercent), [20, 20])
    }
}
