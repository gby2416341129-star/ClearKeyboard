-- Keep the decoder's exact input span with each candidate. This is internal
-- metadata; the keyboard shows candidate text only.
return function(input, env)
  local first = true
  for candidate in input:iter() do
    -- Sentence quality is zero in Rime; the phrase weight is the actual
    -- dictionary/language-model score used by the sentence search. Only the
    -- leading choice participates in the fast-path confidence gate.
    local phrase = first and candidate:get_genuine():to_phrase()
    local weight = phrase and phrase.weight or -1000000
    first = false
    candidate.comment = (candidate.comment or "") .. "\t" .. tostring(candidate._end)
        .. "\t" .. tostring(weight)
    yield(candidate)
  end
end
