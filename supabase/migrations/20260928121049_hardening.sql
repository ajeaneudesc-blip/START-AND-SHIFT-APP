revoke execute on function
  public.handle_new_user(), public.handle_user_contact_update(), public.guard_profile_update(),
  public.guard_brand_limit(), public.set_first_brand_active(), public.requests_before_status(),
  public.requests_after_status(), public.request_messages_after_insert(), public.requests_release_on_cancel(),
  public.guard_portfolio_consent(), public.touch_updated_at()
from public, anon, authenticated;

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
