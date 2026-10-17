-- Keep the decoder's exact input span with each candidate. This is internal
-- metadata; the keyboard shows candidate text only.
return function(input, env)
  for candidate in input:iter() do
    candidate.comment = (candidate.comment or "") .. "\t" .. tostring(candidate._end)
    yield(candidate)
  end
end
