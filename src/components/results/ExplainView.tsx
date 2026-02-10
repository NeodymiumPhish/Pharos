import { useState, useMemo } from 'react';
import { ChevronRight, ChevronDown, Clock, Rows3, Database, Layers } from 'lucide-react';
import { cn } from '@/lib/cn';
import type { ExplainPlanNode } from '@/lib/types';

interface ExplainViewProps {
  plan: ExplainPlanNode[];
  rawJson: string;
  executionTime: number | null;
}

function formatCost(cost: number): string {
  if (cost < 1) return cost.toFixed(3);
  if (cost < 1000) return cost.toFixed(1);
  if (cost < 1_000_000) return `${(cost / 1000).toFixed(1)}K`;
  return `${(cost / 1_000_000).toFixed(1)}M`;
}

function formatTime(ms: number): string {
  if (ms < 1) return `${(ms * 1000).toFixed(0)}μs`;
  if (ms < 1000) return `${ms.toFixed(2)}ms`;
  return `${(ms / 1000).toFixed(2)}s`;
}

function getNodeIcon(nodeType: string): string {
  const t = nodeType.toLowerCase();
  if (t.includes('seq scan')) return '📋';
  if (t.includes('index') && t.includes('scan')) return '🔍';
  if (t.includes('bitmap')) return '🗺️';
  if (t.includes('nested loop')) return '🔄';
  if (t.includes('hash join') || t.includes('merge join')) return '🔗';
  if (t.includes('hash')) return '#️⃣';
  if (t.includes('sort')) return '↕️';
  if (t.includes('aggregate') || t.includes('group')) return '📊';
  if (t.includes('limit')) return '✂️';
  if (t.includes('append')) return '📎';
  if (t.includes('result')) return '📄';
  if (t.includes('materialize')) return '💾';
  if (t.includes('cte')) return '📦';
  if (t.includes('subquery')) return '🔀';
  return '⚙️';
}

function getTimePercentage(node: ExplainPlanNode, rootTotalTime: number): number {
  if (!node['Actual Total Time'] || rootTotalTime <= 0) return 0;
  const nodeTime = node['Actual Total Time'] * (node['Actual Loops'] ?? 1);
  return Math.min(100, (nodeTime / rootTotalTime) * 100);
}

function getTimeColor(pct: number): string {
  if (pct > 50) return 'bg-red-500';
  if (pct > 10) return 'bg-amber-500';
  return 'bg-emerald-500';
}

function getTimeTextColor(pct: number): string {
  if (pct > 50) return 'text-red-400';
  if (pct > 10) return 'text-amber-400';
  return 'text-emerald-400';
}

interface PlanNodeProps {
  node: ExplainPlanNode;
  level: number;
  rootTotalTime: number;
  rootTotalCost: number;
}

function PlanNode({ node, level, rootTotalTime, rootTotalCost }: PlanNodeProps) {
  const [isExpanded, setIsExpanded] = useState(true);
  const hasChildren = node.Plans && node.Plans.length > 0;
  const timePct = getTimePercentage(node, rootTotalTime);
  const costPct = rootTotalCost > 0 ? Math.min(100, (node['Total Cost'] / rootTotalCost) * 100) : 0;
  const hasAnalyze = node['Actual Total Time'] != null;
  const rowsAccuracy = hasAnalyze && node['Actual Rows'] != null
    ? node['Actual Rows'] / Math.max(1, node['Plan Rows'])
    : null;

  return (
    <div className="select-text">
      <div
        className={cn(
          'flex items-start gap-1.5 py-1 px-2 rounded-md cursor-pointer hover:bg-theme-bg-hover transition-colors',
          level === 0 && 'bg-theme-bg-hover/50'
        )}
        style={{ paddingLeft: `${level * 20 + 8}px` }}
        onClick={() => hasChildren && setIsExpanded(!isExpanded)}
      >
        {/* Expand/collapse */}
        <div className="w-4 h-4 flex items-center justify-center flex-shrink-0 mt-0.5">
          {hasChildren ? (
            isExpanded ? (
              <ChevronDown className="w-3.5 h-3.5 text-theme-text-tertiary" />
            ) : (
              <ChevronRight className="w-3.5 h-3.5 text-theme-text-tertiary" />
            )
          ) : null}
        </div>

        {/* Node content */}
        <div className="flex-1 min-w-0">
          {/* Header: icon + node type + relation */}
          <div className="flex items-center gap-1.5 flex-wrap">
            <span className="text-sm">{getNodeIcon(node['Node Type'])}</span>
            <span className="text-xs font-semibold text-theme-text-primary">{node['Node Type']}</span>
            {node['Relation Name'] && (
              <span className="text-xs text-blue-400 font-mono">
                {node['Schema'] ? `${node['Schema']}.` : ''}{node['Relation Name']}
                {node['Alias'] && node['Alias'] !== node['Relation Name'] && ` (${node['Alias']})`}
              </span>
            )}
            {node['Join Type'] && (
              <span className="text-[10px] px-1 py-0.5 rounded bg-violet-500/20 text-violet-400">{node['Join Type']}</span>
            )}
            {node['Index Name'] && (
              <span className="text-xs text-theme-text-muted font-mono">using {node['Index Name']}</span>
            )}
          </div>

          {/* Cost bar */}
          <div className="flex items-center gap-2 mt-1">
            <div className="flex-1 h-1.5 rounded-full bg-theme-bg-surface overflow-hidden max-w-[200px]">
              <div
                className={cn('h-full rounded-full transition-all', hasAnalyze ? getTimeColor(timePct) : 'bg-blue-500')}
                style={{ width: `${hasAnalyze ? timePct : costPct}%` }}
              />
            </div>

            {/* Stats */}
            <div className="flex items-center gap-3 text-[10px] text-theme-text-muted font-mono flex-shrink-0">
              {hasAnalyze && node['Actual Total Time'] != null && (
                <span className={cn('flex items-center gap-0.5', getTimeTextColor(timePct))}>
                  <Clock className="w-3 h-3" />
                  {formatTime(node['Actual Total Time'] * (node['Actual Loops'] ?? 1))}
                  {(node['Actual Loops'] ?? 1) > 1 && (
                    <span className="text-theme-text-tertiary">×{node['Actual Loops']}</span>
                  )}
                </span>
              )}
              {!hasAnalyze && (
                <span className="flex items-center gap-0.5 text-blue-400">
                  cost: {formatCost(node['Startup Cost'])}..{formatCost(node['Total Cost'])}
                </span>
              )}
              <span className="flex items-center gap-0.5">
                <Rows3 className="w-3 h-3" />
                {hasAnalyze && node['Actual Rows'] != null ? (
                  <>
                    {node['Actual Rows'].toLocaleString()}
                    {rowsAccuracy != null && (rowsAccuracy > 10 || rowsAccuracy < 0.1) && (
                      <span className="text-red-400" title={`Estimated ${node['Plan Rows'].toLocaleString()}`}> (est: {node['Plan Rows'].toLocaleString()})</span>
                    )}
                  </>
                ) : (
                  <>{node['Plan Rows'].toLocaleString()} est</>
                )}
              </span>
              {(node['Shared Hit Blocks'] != null || node['Shared Read Blocks'] != null) && (
                <span className="flex items-center gap-0.5">
                  <Database className="w-3 h-3" />
                  {node['Shared Hit Blocks'] != null && `${node['Shared Hit Blocks']} hit`}
                  {node['Shared Read Blocks'] != null && node['Shared Read Blocks'] > 0 && ` ${node['Shared Read Blocks']} read`}
                </span>
              )}
            </div>
          </div>

          {/* Filter / Index Cond */}
          {node['Filter'] && (
            <div className="text-[10px] text-theme-text-muted font-mono mt-0.5 truncate" title={node['Filter']}>
              Filter: {node['Filter']}
              {node['Rows Removed by Filter'] != null && (
                <span className="text-red-400/70 ml-1">({node['Rows Removed by Filter'].toLocaleString()} removed)</span>
              )}
            </div>
          )}
          {node['Index Cond'] && (
            <div className="text-[10px] text-theme-text-muted font-mono mt-0.5 truncate" title={node['Index Cond']}>
              Cond: {node['Index Cond']}
            </div>
          )}
        </div>
      </div>

      {/* Children */}
      {isExpanded && hasChildren && (
        <div>
          {node.Plans!.map((child, i) => (
            <PlanNode
              key={i}
              node={child}
              level={level + 1}
              rootTotalTime={rootTotalTime}
              rootTotalCost={rootTotalCost}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export function ExplainView({ plan, rawJson, executionTime }: ExplainViewProps) {
  const [activeView, setActiveView] = useState<'visual' | 'raw'>('visual');

  // Extract root-level totals for proportional bars
  const rootNode = plan[0];
  const rootTotalTime = useMemo(() => {
    if (!rootNode) return 0;
    return (rootNode['Actual Total Time'] ?? 0) * (rootNode['Actual Loops'] ?? 1);
  }, [rootNode]);
  const rootTotalCost = rootNode?.['Total Cost'] ?? 0;

  // Extract planning/execution times from the wrapper object
  const planningTime = useMemo(() => {
    try {
      const parsed = JSON.parse(rawJson);
      const wrapper = Array.isArray(parsed) ? parsed[0] : parsed;
      return wrapper?.['Planning Time'] ?? null;
    } catch {
      return null;
    }
  }, [rawJson]);

  const explainExecutionTime = useMemo(() => {
    try {
      const parsed = JSON.parse(rawJson);
      const wrapper = Array.isArray(parsed) ? parsed[0] : parsed;
      return wrapper?.['Execution Time'] ?? null;
    } catch {
      return null;
    }
  }, [rawJson]);

  return (
    <div className="h-full flex flex-col overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between px-3 py-1.5 border-b border-theme-border-primary flex-shrink-0">
        <div className="flex items-center gap-2">
          <Layers className="w-3.5 h-3.5 text-violet-400" />
          <span className="text-xs font-medium text-theme-text-primary">Query Plan</span>
          {executionTime !== null && (
            <span className="text-[10px] text-theme-text-muted">({executionTime}ms total)</span>
          )}
        </div>
        <div className="flex items-center gap-0.5 bg-theme-bg-surface rounded-md p-0.5">
          <button
            onClick={() => setActiveView('visual')}
            className={cn(
              'px-2 py-0.5 rounded text-[11px] transition-colors',
              activeView === 'visual'
                ? 'bg-theme-bg-active text-theme-text-primary'
                : 'text-theme-text-tertiary hover:text-theme-text-secondary'
            )}
          >
            Visual
          </button>
          <button
            onClick={() => setActiveView('raw')}
            className={cn(
              'px-2 py-0.5 rounded text-[11px] transition-colors',
              activeView === 'raw'
                ? 'bg-theme-bg-active text-theme-text-primary'
                : 'text-theme-text-tertiary hover:text-theme-text-secondary'
            )}
          >
            Raw JSON
          </button>
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-auto">
        {activeView === 'visual' ? (
          <div className="py-2">
            {/* Summary bar */}
            {(planningTime != null || explainExecutionTime != null) && (
              <div className="flex items-center gap-4 px-3 py-1.5 mb-2 text-[11px] font-mono text-theme-text-muted border-b border-theme-border-primary">
                {planningTime != null && (
                  <span>Planning: {formatTime(planningTime)}</span>
                )}
                {explainExecutionTime != null && (
                  <span>Execution: {formatTime(explainExecutionTime)}</span>
                )}
                {planningTime != null && explainExecutionTime != null && (
                  <span>Total: {formatTime(planningTime + explainExecutionTime)}</span>
                )}
              </div>
            )}

            {/* Plan tree */}
            {plan.map((node, i) => (
              <PlanNode
                key={i}
                node={node}
                level={0}
                rootTotalTime={rootTotalTime}
                rootTotalCost={rootTotalCost}
              />
            ))}
          </div>
        ) : (
          <pre className="p-4 text-xs font-mono text-theme-text-secondary whitespace-pre-wrap select-text">
            {rawJson}
          </pre>
        )}
      </div>
    </div>
  );
}
