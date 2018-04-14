@inline function step!(integrator::SDEIntegrator)
  if integrator.opts.advance_to_tstop
    @inbounds while integrator.tdir*integrator.t < integrator.tdir*top(integrator.opts.tstops)
      loopheader!(integrator)
      @sde_exit_conditions
      perform_step!(integrator,integrator.cache)
      loopfooter!(integrator)
    end
  else
    @inbounds loopheader!(integrator)
    @inbounds perform_step!(integrator,integrator.cache)
    @inbounds loopfooter!(integrator)
    @inbounds while !integrator.accept_step
      loopheader!(integrator)
      @sde_exit_conditions
      perform_step!(integrator,integrator.cache)
      loopfooter!(integrator)
    end
  end
  @inbounds handle_tstop!(integrator)
end
