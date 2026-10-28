import Foundation
import Testing
@testable import BotChuCore
#if canImport(JavaScriptCore)
import JavaScriptCore

/// Exercise user-visible selections and dollar arithmetic against known token/cost fixtures.
struct AnalyticsExplorerTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(AnalyticsDashboard.script)
        #expect(context.exception == nil)
        context.evaluateScript(Self.fixture)
        #expect(context.exception == nil)
        return context
    }

    private static let fixture = #"""
    var prices = [
      {source:'anthropic',model:'claude-opus-4-6',displayName:'Opus 4.6',rates:{input:10,output:50,cacheRead:1,cacheWrite:12},tiers:[]},
      {source:'anthropic',model:'claude-sonnet-4-6',displayName:'Sonnet 4.6',rates:{input:2,output:10,cacheRead:.2,cacheWrite:2.4},tiers:[]}
    ];
    function record(kind,bot,input,read,cost,outcome,hour,taskID) {
      var tokens={uncachedInput:input,cacheRead:read,output:100};
      return {kind:kind,bot:bot,account:bot,project:0,day:'2026-10-28',startedAt:'2026-10-28T'+hour+':00:00Z',taskID:taskID,
        outcome:outcome,seconds:bot===0?60:120,model:'claude-opus-4-6',provider:'claude',tokens:tokens,
        models:[Object.assign({model:'claude-opus-4-6'},tokens)],canReprice:true,cost:cost,costProvenance:'estimated'};
    }
    var fixture={bots:['Fox','Duck'],accounts:[{name:'Personal',family:'Claude Code'},{name:'Work',family:'Claude Code'}],projects:['owner/repo'],prices:prices,
      tasks:[{id:'task-a',latest:'finished',project:0,workNumber:42}],records:[
        record('task',0,1000,0,.015,'failed','10','task-a'),
        record('task',0,1000,0,.015,'finished','11','task-a'),
        record('subagent',1,5000,5000,.06,'finished','12','task-a'),
        record('job',0,1000,0,.015,'finished','13',null),
        record('home',0,1000,0,.015,'finished','14',null)
      ]};
    var E=BotChuAnalytics.createExplorer(fixture),from='2026-10-01',through='2026-10-28';
    """#

    @Test func everyInsightFiltersToItsExactDollarMetric() throws {
        let context = try context()
        let value = try #require(context.evaluateScript("JSON.stringify(E.insights(from,through).map(c=>({id:c.id,value:c.value,filtered:E.metric(E.range(from,through).filter(r=>E.matches(r,c.filters)),c.spec)})))").toString())
        let cards = try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[String: Any]])
        let expected: [String: Double] = ["short": 0.096, "finished": 0.09, "fanout": 0.03, "cache": 0.018, "retry": 0.015, "jobs": 0.012]
        #expect(cards.count == 6)
        var last = Double.infinity
        for card in cards {
            let id = try #require(card["id"] as? String)
            let value = try #require(card["value"] as? Double)
            #expect(abs(value - (expected[id] ?? -1)) < 0.00000001)
            #expect(abs(value - (card["filtered"] as? Double ?? -1)) < 0.00000001)
            #expect(value <= last)
            last = value
        }
        #expect(context.exception == nil)
    }

    @Test func chipsOrWithinDimensionsAndAcrossDimensionsWithoutRepainting() throws {
        let c = try context()
        #expect(c.evaluateScript("E.range(from,through).filter(r=>E.matches(r,[{k:'kind',v:'task'},{k:'kind',v:'job'},{k:'bot',v:'0'}])).length").toInt32() == 3)
        #expect(c.evaluateScript("E.groups(E.range(from,through),'bot','cost',-1)[0].value").toString() == "0")
        #expect(c.evaluateScript("E.color('bot','1')").toString() == "var(--s2)")
        #expect(c.evaluateScript("E.groups(E.range(from,through).filter(r=>E.matches(r,[{k:'bot',v:'1'}])),'bot','cost',-1)[0].value").toString() == "1")
        #expect(c.evaluateScript("E.color('bot','1')").toString() == "var(--s2)")
        #expect(c.evaluateScript("E.label('model','claude-opus-4-6')").toString() == "Opus 4.6")
        #expect(c.evaluateScript("E.range(from,through).filter(r=>E.matches(r,E.insights(from,through)[0].filters.concat([{k:'bot',v:'1'}]))).length").toInt32() == 1)
    }

    @Test func unknownUsageNeverBecomesFreeSpendOrInventedSavings() throws {
        let c = try context()
        c.evaluateScript("fixture.records[0].cost=null;fixture.records[0].costProvenance='unpriced';fixture.records[0].canReprice=false;fixture.records[1].canReprice=false;E=BotChuAnalytics.createExplorer(fixture)")
        #expect(c.evaluateScript("BotChuAnalytics.money(E.aggregate([fixture.records[0]]).cost)").toString() == "—")
        #expect(c.evaluateScript("E.range(from,through).filter(r=>E.matches(r,[{k:'price',v:'unpriced'}])).length").toInt32() == 1)
        #expect(c.evaluateScript("E.comparison(fixture.records[0],'swap')===null&&E.comparison(fixture.records[1],'swap')===null").toBool() == true)
        // No inference that an expensive unknown product is a top model.
        c.evaluateScript("fixture.records[2].models[0].model='unknown-expensive-model'")
        #expect(c.evaluateScript("E.comparison(fixture.records[2],'swap')===null").toBool() == true)
        #expect(c.evaluateScript("E.insights(from,through).find(c=>c.id==='fanout').value===null").toBool() == true)
    }

    @Test func dollarAxisKeepsFractionalAndSubCentTicksExact() throws {
        let c = try context()
        #expect(c.evaluateScript("BotChuAnalytics.dollarTick(2.5,2.5)").toString() == "$2.5")
        #expect(c.evaluateScript("BotChuAnalytics.dollarTick(7.5,2.5)").toString() == "$7.5")
        #expect(c.evaluateScript("BotChuAnalytics.dollarTick(.001,.00025)").toString() == "$0.00100")
        #expect(c.evaluateScript("BotChuAnalytics.dollarTick(0,.00025)").toString() == "$0.00000")
        #expect(c.evaluateScript("BotChuAnalytics.dollarTick(100,25)").toString() == "$100")
    }

    @Test func reasoningOnlyLowerBoundCannotEstablishShortOutput() throws {
        let c = try context()
        c.evaluateScript("fixture.records[0].models[0].output=null;fixture.records[0].models[0].reasoning=100;fixture.records[0].tokens.output=100;E=BotChuAnalytics.createExplorer(fixture)")
        #expect(c.evaluateScript("E.insights(from,through).find(c=>c.id==='short').filters[0].ids.includes(0)").toBool() == false)
        #expect(c.evaluateScript("E.insights(from,through).find(c=>c.id==='short').filters[0].ids.length").toInt32() == 4)
    }

    @Test func providerBackendsAndMissingUsageRemainDistinct() throws {
        let c = try context()
        c.evaluateScript("fixture.records[0].provider='pi';fixture.records[0].providerID='openrouter';fixture.records[1].provider='pi';fixture.records[1].providerID='radius';fixture.records[0].cost=null;fixture.records[0].costProvenance='unpriced';fixture.records[1].cost=null;fixture.records[1].costProvenance='unavailable';E=BotChuAnalytics.createExplorer(fixture)")
        #expect(c.evaluateScript("E.groups(E.range(from,through),'provider','name',1).map(g=>g.label).join(',')").toString() == "Claude Code,OpenRouter,Radius")
        #expect(c.evaluateScript("E.label('model','claude-opus-4-6')").toString() == "Opus 4.6")
        #expect(c.evaluateScript("E.resolve('claude-opus-4-6',fixture.records[1])===null").toBool() == true)
        #expect(c.evaluateScript("E.range(from,through).filter(r=>E.matches(r,[{k:'price',v:'unpriced'}])).length").toInt32() == 1)
        #expect(c.evaluateScript("E.range(from,through).filter(r=>E.matches(r,[{k:'price',v:'unavailable'}])).length").toInt32() == 1)
    }

    @Test func repricingHonorsContextTiersSubsetBucketsAndMissingRates() throws {
        let c = try context()
        c.evaluateScript("var price={rates:{input:1,output:2,cacheRead:.1,cacheWrite:1.25},tiers:[{aboveInput:100,rates:{input:3,output:6,cacheRead:.3,cacheWrite:3.75}}]}")
        #expect(abs(c.evaluateScript("E.priceAt({uncachedInput:100,cacheRead:0,output:50,reasoning:20},price)").toDouble() - 0.0002) < 0.00000001)
        #expect(abs(c.evaluateScript("E.priceAt({uncachedInput:101,cacheWrite:10,cacheWrite1h:4,output:50,reasoning:20},price)").toDouble() - 0.0006495) < 0.00000001)
        #expect(c.evaluateScript("E.priceAt({cacheRead:10},{rates:{input:1,output:2}})===null").toBool() == true)
        #expect(c.evaluateScript("E.priceAt({},price)===null").toBool() == true)
        #expect(c.evaluateScript("E.priceAt({cacheWrite:1,cacheWrite1h:2},price)===null").toBool() == true)
    }

    @Test func everyBreakdownColumnSortsAndGroupedSpendEqualsKPIs() throws {
        let c = try context()
        #expect(c.evaluateScript("E.groups(E.range(from,through),'bot','name',1)[0].label").toString() == "Duck")
        #expect(c.evaluateScript("E.groups(E.range(from,through),'bot','name',-1)[0].label").toString() == "Fox")
        #expect(c.evaluateScript("['runs','finished','failureRate','totalTokens','cacheHitRate','cost','costPerFinishedTask','medianSeconds','share'].every(k=>{let up=E.groups(E.range(from,through),'bot',k,1),down=E.groups(E.range(from,through),'bot',k,-1);let field=k==='share'?'cost':k;let value=g=>k==='finished'?g.summary.outcomes.finished||0:g.summary[field];return value(up[0])<=value(up[1])&&value(down[0])>=value(down[1])})").toBool() == true)
        #expect(abs(c.evaluateScript("E.groups(E.range(from,through),'bot','cost',-1).reduce((s,g)=>s+g.summary.cost,0)-E.aggregate(E.range(from,through)).cost").toDouble()) < 0.00000001)
        #expect(abs(c.evaluateScript("E.aggregate(E.range(from,through)).costPerFinishedTask").toDouble() - 0.09) < 0.00000001)
        #expect(c.exception == nil)
    }
}
#endif
